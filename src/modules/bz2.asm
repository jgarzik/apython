; bz2.asm - the `_bz2core` module: libbzip2's bz_stream, and nothing else.
;
; The same split src/modules/zlib.asm's header states as a contract.  What is
; genuinely C lives here -- the bz_stream, the output buffer that has to grow
; while the codec writes into it, the handle table -- and everything a Python
; program sees is lib/_bz2.py: the BZ2Compressor and BZ2Decompressor objects,
; the attributes CPython's bz2.py reads off them, and the exception classes.
; So every function here takes a fixed number of positional arguments and
; answers with a bytes, an int or a tuple.
;
; And it is a SHIM, on the precedent -lz and -lgmp set.  bzip2's Burrows-
; Wheeler transform is a sorting problem, and a thousand lines of hand-written
; block sort would serve nobody: tarfile, zipfile and shutil reach for this
; through CPython's own bz2.py, and they care about speed.
;
; A handle is an INDEX into bc_handles, not a pointer.  A pointer would be an
; integer a Python program could forge and this module would dereference; an
; index is bounds-checked and a freed slot reads back as 0.
;
; The decompressor HOLDS the input it did not consume, which is what
; BZ2Decompressor.needs_input reports and what makes a max_length loop work
; without the caller feeding the leftover back.  zlib.Decompress is the other
; way round and needed stream_drop_tail for it; bz2 has no such object, so
; there is nothing here to drop.

%include "macros.inc"
%include "object.inc"

ASM_INIT

extern eval_exception_unwind
extern none_singleton
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
extern memoryview_type
extern tuple_new
extern ap_malloc
extern ap_realloc
extern ap_free
extern ap_memcpy
extern ap_memset
extern obj_as_index
extern raise_type_error_with_name
extern exc_TypeError_type
extern exc_ValueError_type
extern exc_BufferError_type
extern raise_exception
extern bool_true
extern bool_false

extern BZ2_bzCompressInit
extern BZ2_bzCompress
extern BZ2_bzCompressEnd
extern BZ2_bzDecompressInit
extern BZ2_bzDecompress
extern BZ2_bzDecompressEnd

BC_MAGIC       equ 0x425A4C49      ; "BZLI"
BC_INITIAL_OUT equ 8192
BC_MAX32       equ 0x7FFFFFFF      ; avail_in and avail_out are 32-bit

BZ_RUN         equ 0
BZ_FINISH      equ 2
BZ_OK          equ 0
BZ_STREAM_END  equ 4

BC_COMPRESS    equ 0
BC_DECOMPRESS  equ 1

; libbzip2's bz_stream, taken from the header with offsetof rather than
; guessed -- the two 32-bit counters between the pointers are exactly where a
; hand-written layout goes wrong.
struc BzStream
    .next_in:       resq 1  ; +0
    .avail_in:      resd 1  ; +8
    .total_in_lo:   resd 1  ; +12
    .total_in_hi:   resd 1  ; +16
    .bpad0:         resd 1  ; +20
    .next_out:      resq 1  ; +24
    .avail_out:     resd 1  ; +32
    .total_out_lo:  resd 1  ; +36
    .total_out_hi:  resd 1  ; +40
    .bpad1:         resd 1  ; +44
    .state:         resq 1  ; +48
    .bzalloc:       resq 1  ; +56
    .bzfree:        resq 1  ; +64
    .opaque:        resq 1  ; +72
endstruc                    ; sizeof = 80

struc BHandle
    ; The bz_stream first, so it inherits the allocator's alignment, for the
    ; reason zlib.asm's ZHandle gives.
    .bs:         resb BzStream_size
    .mode:       resq 1  ; BC_COMPRESS or BC_DECOMPRESS
    .eof:        resq 1  ; the decoder reached BZ_STREAM_END
    .ended:      resq 1  ; bzCompressEnd/bzDecompressEnd has run
    .needs_input: resq 1 ; what CPython's rule below makes it
    .tail:       resq 1  ; input the last feed did not consume, ours to free
    .tail_len:   resq 1
    .unused:     resq 1  ; input past the end of the stream, ours
    .unused_len: resq 1
    .magic:      resq 1  ; BC_MAGIC while the handle is open, 0 once freed
endstruc

section .bss
bc_handles:    resq 1
bc_handle_n:   resq 1
bc_handle_cap: resq 1

section .text

;; ============================================================================
;; bc_handle_at(rdi = handle index) -> rax = BHandle*, or 0
;;
;; Bounds-checked and magic-checked, because the index came from Python.
;; ============================================================================
DEF_FUNC_BARE bc_handle_at
    xor eax, eax
    test rdi, rdi
    js .bha_no
    cmp rdi, [rel bc_handle_n]
    jae .bha_no
    mov rax, [rel bc_handles]
    test rax, rax
    jz .bha_no
    mov rax, [rax + rdi*8]
    test rax, rax
    jz .bha_no
    cmp qword [rax + BHandle.magic], BC_MAGIC
    je .bha_out
    xor eax, eax
.bha_out:
.bha_no:
    ret
END_FUNC bc_handle_at

;; ============================================================================
;; bc_arg_int(rdi = args, rsi = index) -> rax = the int
;;
;; Does not return when the argument is not an index.
;; ============================================================================
DEF_FUNC_BARE bc_arg_int
    mov rdi, [rdi + rsi*8]
    V_UNPACK rdi, rdx
    sub rsp, 8                  ; a call, so the refusal can be seen
    call obj_as_index
    add rsp, 8
    ERR_M1_JUMP
    ret
END_FUNC bc_arg_int

;; ============================================================================
;; bc_buffer(rdi = a Value) -> rax = data pointer, rdx = length, rax = 0 when
;;   it is neither bytes nor bytearray
;;
;; A str is refused rather than encoded, as it is for zlib: guessing an
;; encoding would be worse than the error.
;; ============================================================================
DEF_FUNC_BARE bc_buffer
    V_TEST_PTR rdi, rax
    ja .bb_no
    test rdi, rdi
    jz .bb_no
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel bytes_type]
    cmp rax, rcx
    je .bb_bytes
    lea rcx, [rel bytearray_type]
    cmp rax, rcx
    je .bb_bytearray
    lea rcx, [rel memoryview_type]
    cmp rax, rcx
    jne .bb_no
    ; A memoryview reaches here from BZ2File.write, which hands one on to keep
    ; from copying an array.array; only a CONTIGUOUS, live one has a buffer to
    ; point at.
    mov rax, [rdi + PyMemoryViewObject.mv_buf]
    test rax, rax
    jz .bb_no
    cmp qword [rdi + PyMemoryViewObject.mv_stride], 1
    jne .bb_strided
    mov rdx, [rdi + PyMemoryViewObject.mv_len]
    ret
.bb_strided:
    ; CPython refuses this where the buffer is asked for, and says so in
    ; those words rather than blaming the argument's type.
    RAISE exc_BufferError_type, "memoryview: underlying buffer is not C-contiguous"
.bb_bytearray:
    mov rdx, [rdi + PyByteArrayObject.ob_size]
    mov rax, [rdi + PyByteArrayObject.ob_bytes]
    ret
.bb_bytes:
    mov rdx, [rdi + PyBytesObject.ob_size]
    lea rax, [rdi + PyBytesObject.data]
    ret
.bb_no:
    xor eax, eax
    xor edx, edx
    ret
END_FUNC bc_buffer

;; ============================================================================
;; bc_raise_bz(rdi = the libbzip2 return code) -> does not return
;;
;; The sentence CPython's _bz2module.c uses for that code, raised as a
;; ValueError because a module written in assembly cannot raise a class
;; defined in Python.  lib/_bz2.py maps the sentence back to the class CPython
;; raises; the mapping is by exact text, and both halves say so.
;; ============================================================================
DEF_FUNC bc_raise_bz
    cmp edi, -3
    je .brz_mem
    cmp edi, -4
    je .brz_data
    cmp edi, -5
    je .brz_data
    cmp edi, -7
    je .brz_eof
    cmp edi, -1
    je .brz_seq
    cmp edi, -2
    je .brz_param
    RAISE exc_ValueError_type, "Unknown I/O error"
.brz_mem:
    RAISE exc_ValueError_type, "Out of memory"
.brz_data:
    RAISE exc_ValueError_type, "Invalid data stream"
.brz_eof:
    RAISE exc_ValueError_type, "Compressed file ended before the end-of-stream marker was reached"
.brz_seq:
    RAISE exc_ValueError_type, "Internal error - calls to libbzip2 in wrong order"
.brz_param:
    RAISE exc_ValueError_type, "Internal error - invalid parameters"
END_FUNC bc_raise_bz

;; ============================================================================
;; bc_slot(rdi = BHandle*) -> rax = the handle index, edx = TAG_SMALLINT
;;
;; Files the stream in the table, reusing a slot a free gave back.  Does not
;; return when the table cannot grow.
;; ============================================================================
BS_H     equ 8
BS_CAP   equ 16
BS_FRAME equ 24             ; + 1 push = 32, 16-aligned
DEF_FUNC_LOCAL bc_slot, BS_FRAME
    push rbx
    mov rbx, rdi
    xor ecx, ecx
    mov rdx, [rel bc_handles]
    test rdx, rdx
    jz .bs_grow
.bs_scan:
    cmp rcx, [rel bc_handle_n]
    jae .bs_grow
    cmp qword [rdx + rcx*8], 0
    je .bs_have
    inc rcx
    jmp .bs_scan

.bs_grow:
    mov rax, [rel bc_handle_n]
    cmp rax, [rel bc_handle_cap]
    jb .bs_no_grow
    mov rsi, [rel bc_handle_cap]
    test rsi, rsi
    jnz .bs_double
    mov esi, 8
    jmp .bs_realloc
.bs_double:
    add rsi, rsi
.bs_realloc:
    mov [rbp - BS_CAP], rsi
    shl rsi, 3
    mov rdi, [rel bc_handles]
    call ap_realloc
    test rax, rax
    jz .bs_oom
    mov [rel bc_handles], rax
    mov rcx, [rbp - BS_CAP]
    mov [rel bc_handle_cap], rcx
.bs_no_grow:
    mov rcx, [rel bc_handle_n]
    inc qword [rel bc_handle_n]
    mov rdx, [rel bc_handles]

.bs_have:
    mov [rdx + rcx*8], rbx
    mov rdi, rcx
    call int_from_i64
    pop rbx
    leave
    ret

.bs_oom:
    pop rbx
    RAISE exc_ValueError_type, "Out of memory"
END_FUNC bc_slot

;; ============================================================================
;; _bz2core.stream_new(mode, level) -> int handle
;;
;; mode 0 opens a compressor at `level`, which is libbzip2's blockSize100k and
;; is the compresslevel CPython's BZ2Compressor takes; 1 opens a decompressor.
;; verbosity and workFactor are 0, as CPython passes them.
;; ============================================================================
BN_H     equ 8
BN_MODE  equ 16
BN_LEVEL equ 24
BN_FRAME equ 32             ; + 0 pushes = 32, 16-aligned
DEF_FUNC bc_stream_new, BN_FRAME
    cmp rsi, 2
    jne .bn_nargs
    push rdi
    sub rsp, 8
    xor esi, esi
    call bc_arg_int
    mov [rbp - BN_MODE], rax
    mov rdi, [rsp + 8]
    mov esi, 1
    call bc_arg_int
    mov [rbp - BN_LEVEL], rax
    add rsp, 8
    pop rdi

    mov edi, BHandle_size
    call ap_malloc
    test rax, rax
    jz .bn_mem
    mov [rbp - BN_H], rax
    mov rdi, rax
    xor esi, esi
    mov edx, BHandle_size
    call ap_memset

    mov rax, [rbp - BN_H]
    mov qword [rax + BHandle.magic], BC_MAGIC
    mov rcx, [rbp - BN_MODE]
    mov [rax + BHandle.mode], rcx
    mov qword [rax + BHandle.needs_input], 1
    lea rdi, [rax + BHandle.bs]
    cmp rcx, BC_COMPRESS
    jne .bn_decompress
    mov esi, [rbp - BN_LEVEL]   ; blockSize100k
    xor edx, edx                ; verbosity
    xor ecx, ecx                ; workFactor: 0 is libbzip2's default
    call BZ2_bzCompressInit wrt ..plt
    jmp .bn_check
.bn_decompress:
    xor esi, esi                ; verbosity
    xor edx, edx                ; small
    call BZ2_bzDecompressInit wrt ..plt
.bn_check:
    test eax, eax
    jnz .bn_failed

    mov rdi, [rbp - BN_H]
    call bc_slot
    leave
    V_PACK rax, rdx
    ret

.bn_failed:
    mov rdi, [rbp - BN_H]
    call ap_free
    RAISE exc_ValueError_type, "Internal error - invalid parameters"
.bn_mem:
    RAISE exc_ValueError_type, "Out of memory"
.bn_nargs:
    RAISE exc_TypeError_type, "_bz2core: wrong number of arguments"
END_FUNC bc_stream_new

;; ============================================================================
;; _bz2core.stream_feed(handle, data, action, max_length) -> bytes
;;
;; Push `data` through the stream and answer everything that came out.  The
;; input is COPIED first, and whatever the last call did not consume is copied
;; in front of it: libbzip2 keeps next_in pointing into that buffer for the
;; length of the loop, and a bytes handed in from Python is not ours to pin.
;;
;; action is BZ_RUN or BZ_FINISH, and is ignored by the decompressor, which
;; has only one.  A max_length of 0 or more stops once that much output exists
;; and parks the rest of the input in the handle, where the next call picks it
;; up -- which is what BZ2Decompressor(max_length=...) is for; NEGATIVE means
;; no cap.  Zero has to be a real cap and not the spelling of "unlimited":
;; `decompress(data, 0)` answers b"" in CPython and consumes nothing.
;;
;; avail_in and avail_out are 32-bit, so the loop tops the input up rather
;; than assuming one pass can be handed everything.
;; ============================================================================
BF_ARGS   equ 8
BF_INBUF  equ 16            ; the owned input copy
BF_INLEFT equ 24            ; input not yet shown to libbzip2
BF_INAT   equ 32            ; where that input starts
BF_ACTION equ 40
BF_MAX    equ 48
BF_OUT    equ 56            ; the owned output buffer
BF_OUTCAP equ 64
BF_OUTLEN equ 72
BF_RES    equ 80            ; the bytes, while the buffers are freed
BF_CODE   equ 88            ; the libbzip2 return code, across a call
BF_FRAME  equ 96            ; + 2 pushes = 112, 16-aligned
DEF_FUNC bc_stream_feed, BF_FRAME
    push rbx
    push r12
    mov r12, rsp
    and rsp, -16                ; the same precaution zc_stream_feed takes
    cmp rsi, 4
    jne .bf_nargs
    mov [rbp - BF_ARGS], rdi
    mov qword [rbp - BF_INBUF], 0
    mov qword [rbp - BF_OUT], 0

    xor esi, esi
    call bc_arg_int
    mov rdi, rax
    call bc_handle_at
    test rax, rax
    jz .bf_bad_handle
    mov rbx, rax
    cmp qword [rbx + BHandle.ended], 0
    jne .bf_ended

    mov rdi, [rbp - BF_ARGS]
    mov esi, 2
    call bc_arg_int
    mov [rbp - BF_ACTION], rax
    mov rdi, [rbp - BF_ARGS]
    mov esi, 3
    call bc_arg_int
    mov [rbp - BF_MAX], rax

    ; --- the input: the handle's leftover, then what was handed in ---------
    mov rdi, [rbp - BF_ARGS]
    mov rdi, [rdi + 8]
    call bc_buffer
    test rax, rax
    jnz .bf_have_buf
    mov rdx, [rbp - BF_ARGS]
    cmp qword [rdx + 8], 0      ; an empty bytes is a pointer, so 0 is a type
    jmp .bf_type                ; error however it got here
.bf_have_buf:
    mov r10, rax                ; the caller's data, borrowed
    mov r11, rdx                ; its length
    mov rax, [rbx + BHandle.tail_len]
    add rax, r11
    mov [rbp - BF_INLEFT], rax
    test rax, rax
    jz .bf_input_ready

    push r10
    push r11
    mov rdi, rax
    call ap_malloc
    pop r11
    pop r10
    test rax, rax
    jz .bf_mem
    mov [rbp - BF_INBUF], rax

    mov rdx, [rbx + BHandle.tail_len]
    test rdx, rdx
    jz .bf_copy_new
    push r10
    push r11
    mov rdi, rax
    mov rsi, [rbx + BHandle.tail]
    call ap_memcpy
    pop r11
    pop r10
.bf_copy_new:
    test r11, r11
    jz .bf_input_ready
    mov rdi, [rbp - BF_INBUF]
    add rdi, [rbx + BHandle.tail_len]
    mov rsi, r10
    mov rdx, r11
    call ap_memcpy

.bf_input_ready:
    ; The leftover has been folded in; the handle no longer owns it.
    mov rdi, [rbx + BHandle.tail]
    mov qword [rbx + BHandle.tail], 0
    mov qword [rbx + BHandle.tail_len], 0
    test rdi, rdi
    jz .bf_tail_gone
    call ap_free
.bf_tail_gone:
    mov rax, [rbp - BF_INBUF]
    mov [rbp - BF_INAT], rax
    mov qword [rbx + BHandle.bs + BzStream.next_in], 0
    mov dword [rbx + BHandle.bs + BzStream.avail_in], 0

    ; --- the output buffer -------------------------------------------------
    ;
    ; A max_length smaller than the default sizes the buffer exactly, for the
    ; reason zc_stream_feed states: a buffer larger than the cap means the
    ; codec finishes in one pass and the cap is never reached.
    mov rdi, BC_INITIAL_OUT
    mov rcx, [rbp - BF_MAX]
    test rcx, rcx
    js .bf_out_size
    cmp rcx, rdi
    jae .bf_out_size
    mov rdi, rcx
    test rdi, rdi
    jnz .bf_out_size
    mov edi, 1                  ; a cap of 0 still needs an allocation
.bf_out_size:
    mov [rbp - BF_OUTCAP], rdi
    call ap_malloc
    test rax, rax
    jz .bf_mem
    mov [rbp - BF_OUT], rax
    mov qword [rbp - BF_OUTLEN], 0

.bf_loop:
    ; The cap, tested BEFORE the call: a cap of 0 has to produce nothing at
    ; all, and testing it only when the output buffer fills would produce one
    ; byte first.
    mov rcx, [rbp - BF_MAX]
    test rcx, rcx
    js .bf_no_cap
    cmp [rbp - BF_OUTLEN], rcx
    jae .bf_done
.bf_no_cap:
    ; Top the input up: avail_in is 32-bit and the buffer need not be.
    cmp dword [rbx + BHandle.bs + BzStream.avail_in], 0
    jne .bf_input_set
    mov rax, [rbp - BF_INLEFT]
    test rax, rax
    jz .bf_input_set
    cmp rax, BC_MAX32
    jbe .bf_in_chunk
    mov eax, BC_MAX32
.bf_in_chunk:
    mov rcx, [rbp - BF_INAT]
    mov [rbx + BHandle.bs + BzStream.next_in], rcx
    mov [rbx + BHandle.bs + BzStream.avail_in], eax
    add [rbp - BF_INAT], rax
    sub [rbp - BF_INLEFT], rax
.bf_input_set:
    ; A BZ_RUN with nothing to run on is not a no-op to libbzip2: it answers
    ; BZ_PARAM_ERROR, because "no progress" and "bad call" are the same code
    ; there.  CPython's loop breaks at exactly this point for the same
    ; reason, which is what makes BZ2Compressor().compress(b"") answer b"".
    cmp qword [rbx + BHandle.mode], BC_COMPRESS
    jne .bf_have_work
    cmp qword [rbp - BF_ACTION], BZ_RUN
    jne .bf_have_work
    cmp dword [rbx + BHandle.bs + BzStream.avail_in], 0
    je .bf_done
.bf_have_work:

    mov rax, [rbp - BF_OUT]
    add rax, [rbp - BF_OUTLEN]
    mov [rbx + BHandle.bs + BzStream.next_out], rax
    mov rax, [rbp - BF_OUTCAP]
    sub rax, [rbp - BF_OUTLEN]
    cmp rax, BC_MAX32
    jbe .bf_out_chunk
    mov eax, BC_MAX32
.bf_out_chunk:
    mov [rbx + BHandle.bs + BzStream.avail_out], eax

    ; Remember what was there, so a pass that moved nothing can be told from
    ; one that did: libbzip2 answers BZ_RUN_OK either way.
    mov r8d, [rbx + BHandle.bs + BzStream.avail_in]
    mov r9d, [rbx + BHandle.bs + BzStream.avail_out]
    push r8
    push r9

    lea rdi, [rbx + BHandle.bs]
    cmp qword [rbx + BHandle.mode], BC_COMPRESS
    jne .bf_decompress
    mov esi, [rbp - BF_ACTION]
    call BZ2_bzCompress wrt ..plt
    jmp .bf_after
.bf_decompress:
    call BZ2_bzDecompress wrt ..plt
.bf_after:
    mov [rbp - BF_CODE], rax
    pop r9
    pop r8

    ; What came out: next_out has moved.
    mov rax, [rbx + BHandle.bs + BzStream.next_out]
    sub rax, [rbp - BF_OUT]
    mov [rbp - BF_OUTLEN], rax

    mov eax, [rbp - BF_CODE]
    cmp eax, BZ_STREAM_END
    je .bf_stream_end
    test eax, eax
    js .bf_bzerror

    ; Full output buffer: grow, unless the cap is reached.
    cmp dword [rbx + BHandle.bs + BzStream.avail_out], 0
    jne .bf_room_left

    mov rcx, [rbp - BF_MAX]
    test rcx, rcx
    js .bf_grow
    cmp [rbp - BF_OUTLEN], rcx
    jae .bf_done                ; the cap is reached; park the rest
.bf_grow:
    mov rax, [rbp - BF_OUTCAP]
    add rax, rax
    mov rcx, [rbp - BF_MAX]
    test rcx, rcx
    js .bf_grow_to
    cmp rax, rcx
    jbe .bf_grow_to
    mov rax, rcx                ; never past the ceiling the caller named
.bf_grow_to:
    mov rdi, [rbp - BF_OUT]
    mov rsi, rax
    push rax
    sub rsp, 8
    call ap_realloc
    add rsp, 8
    pop rcx
    test rax, rax
    jz .bf_mem
    mov [rbp - BF_OUT], rax
    mov [rbp - BF_OUTCAP], rcx
    jmp .bf_loop

.bf_room_left:
    ; Room to spare.  A decompressor with nothing left to show it is done for
    ; this call; a compressor being FINISHED keeps going until libbzip2 says
    ; BZ_STREAM_END, because the block it is holding has still to come out.
    cmp dword [rbx + BHandle.bs + BzStream.avail_in], 0
    jne .bf_progress
    cmp qword [rbp - BF_INLEFT], 0
    jne .bf_progress
    cmp qword [rbx + BHandle.mode], BC_COMPRESS
    jne .bf_done
    cmp qword [rbp - BF_ACTION], BZ_FINISH
    jne .bf_done
.bf_progress:
    ; A pass that moved nothing at all would otherwise spin.
    mov ecx, [rbx + BHandle.bs + BzStream.avail_in]
    cmp ecx, r8d
    jne .bf_loop
    mov ecx, [rbx + BHandle.bs + BzStream.avail_out]
    cmp ecx, r9d
    jne .bf_loop
    jmp .bf_done                ; nothing moved: stop rather than spin

.bf_stream_end:
    mov qword [rbx + BHandle.eof], 1
    ; Input past the end of the stream is the caller's unused_data.  Whatever
    ; libbzip2 has not looked at yet counts too.
    mov ecx, [rbx + BHandle.bs + BzStream.avail_in]
    add rcx, [rbp - BF_INLEFT]
    test rcx, rcx
    jz .bf_no_tail
    mov rdi, rcx
    push rcx
    sub rsp, 8
    call ap_malloc
    add rsp, 8
    pop rcx
    test rax, rax
    jz .bf_no_tail
    mov [rbx + BHandle.unused], rax
    mov [rbx + BHandle.unused_len], rcx
    mov rdi, rax
    mov rsi, [rbx + BHandle.bs + BzStream.next_in]
    mov edx, [rbx + BHandle.bs + BzStream.avail_in]
    call ap_memcpy
    ; ...and the part that was never shown to it.
    mov rcx, [rbp - BF_INLEFT]
    test rcx, rcx
    jz .bf_no_tail
    mov rdi, [rbx + BHandle.unused]
    mov edx, [rbx + BHandle.bs + BzStream.avail_in]
    add rdi, rdx
    mov rsi, [rbp - BF_INAT]
    mov rdx, rcx
    call ap_memcpy
    jmp .bf_no_tail

.bf_done:
    ; Whatever is left unconsumed is parked in the handle, and has to outlive
    ; the input copy this call owns.
    mov ecx, [rbx + BHandle.bs + BzStream.avail_in]
    add rcx, [rbp - BF_INLEFT]
    test rcx, rcx
    jz .bf_no_tail
    mov rdi, rcx
    push rcx
    sub rsp, 8
    call ap_malloc
    add rsp, 8
    pop rcx
    test rax, rax
    jz .bf_no_tail
    mov [rbx + BHandle.tail], rax
    mov [rbx + BHandle.tail_len], rcx
    mov rdi, rax
    mov rsi, [rbx + BHandle.bs + BzStream.next_in]
    mov edx, [rbx + BHandle.bs + BzStream.avail_in]
    call ap_memcpy
    mov rcx, [rbp - BF_INLEFT]
    test rcx, rcx
    jz .bf_no_tail
    mov rdi, [rbx + BHandle.tail]
    mov edx, [rbx + BHandle.bs + BzStream.avail_in]
    add rdi, rdx
    mov rsi, [rbp - BF_INAT]
    mov rdx, rcx
    call ap_memcpy

.bf_no_tail:
    ; needs_input, by CPython's rule: false when the stream has ended, false
    ; when input is parked, and false when the output buffer filled exactly at
    ; the cap -- the codec may still be holding bytes that the next call will
    ; emit, and a caller told to read more of the file would stall.
    mov eax, 1
    cmp qword [rbx + BHandle.eof], 0
    jne .bf_no_need
    cmp qword [rbx + BHandle.tail_len], 0
    jne .bf_no_need
    mov rcx, [rbp - BF_MAX]
    test rcx, rcx
    js .bf_set_need
    cmp [rbp - BF_OUTLEN], rcx
    jb .bf_set_need
.bf_no_need:
    xor eax, eax
.bf_set_need:
    mov [rbx + BHandle.needs_input], rax

    mov dword [rbx + BHandle.bs + BzStream.avail_in], 0
    mov qword [rbx + BHandle.bs + BzStream.next_in], 0
    mov qword [rbp - BF_INLEFT], 0

    mov rdi, [rbp - BF_OUT]
    mov rsi, [rbp - BF_OUTLEN]
    call bytes_from_data
    test rax, rax
    jz .bf_mem
    mov [rbp - BF_RES], rax
    call bc_release_buffers
    mov rax, [rbp - BF_RES]
    mov edx, TAG_PTR
    mov rsp, r12
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.bf_bzerror:
    call bc_release_buffers
    mov edi, [rbp - BF_CODE]
    leave
    jmp bc_raise_bz
.bf_mem:
    call bc_release_buffers
    RAISE exc_ValueError_type, "Out of memory"
.bf_type:
    lea rdi, [rel bc_e_notbytes]
    mov rsi, [rbp - BF_ARGS]
    mov rsi, [rsi + 8]
    leave
    jmp raise_type_error_with_name
.bf_bad_handle:
    RAISE exc_ValueError_type, "invalid stream handle"
.bf_ended:
    RAISE exc_ValueError_type, "Internal error - calls to libbzip2 in wrong order"
.bf_nargs:
    RAISE exc_TypeError_type, "_bz2core: wrong number of arguments"

;; The two malloc'd buffers this call owns, released on every way out.  A
;; local label rather than a function, because it reads the caller's frame.
bc_release_buffers:
    mov rdi, [rbp - BF_INBUF]
    mov qword [rbp - BF_INBUF], 0
    test rdi, rdi
    jz .brb_out
    push rax
    sub rsp, 8
    call ap_free
    add rsp, 8
    pop rax
.brb_out:
    mov rdi, [rbp - BF_OUT]
    mov qword [rbp - BF_OUT], 0
    test rdi, rdi
    jz .brb_done
    push rax
    sub rsp, 8
    call ap_free
    add rsp, 8
    pop rax
.brb_done:
    ret
END_FUNC bc_stream_feed

;; ============================================================================
;; _bz2core.stream_state(handle) -> (eof, needs_input, unused_data)
;;
;; The three things a BZ2Decompressor reports and cannot compute for itself.
;; unused_data is taken away by this call, because lib/_bz2.py accumulates it
;; into the attribute a caller reads and must not be handed it twice.
;; ============================================================================
BT_H     equ 8
BT_TUP   equ 16
BT_FRAME equ 32             ; + 0 pushes = 32, 16-aligned
DEF_FUNC bc_stream_state, BT_FRAME
    cmp rsi, 1
    jne .bt_nargs
    xor esi, esi
    call bc_arg_int
    mov rdi, rax
    call bc_handle_at
    test rax, rax
    jz .bt_bad_handle
    mov [rbp - BT_H], rax

    mov edi, 3
    call tuple_new
    test rax, rax
    jz .bt_mem
    mov [rbp - BT_TUP], rax

    mov rcx, [rbp - BT_H]
    lea rax, [rel bool_false]
    cmp qword [rcx + BHandle.eof], 0
    je .bt_have_eof
    lea rax, [rel bool_true]
.bt_have_eof:
    INCREF rax
    mov rdx, [rbp - BT_TUP]
    mov rdx, [rdx + PyTupleObject.ob_item]
    mov [rdx], rax

    ; needs_input as the last feed worked it out; see the rule there.
    mov rcx, [rbp - BT_H]
    lea rax, [rel bool_false]
    cmp qword [rcx + BHandle.needs_input], 0
    je .bt_have_needs
    lea rax, [rel bool_true]
.bt_have_needs:
    INCREF rax
    mov rdx, [rbp - BT_TUP]
    mov rdx, [rdx + PyTupleObject.ob_item]
    mov [rdx + 8], rax

    mov rcx, [rbp - BT_H]
    mov rdi, [rcx + BHandle.unused]
    mov rsi, [rcx + BHandle.unused_len]
    call bc_bytes_or_empty
    test rax, rax
    jz .bt_mem
    mov rdx, [rbp - BT_TUP]
    mov rdx, [rdx + PyTupleObject.ob_item]
    mov [rdx + 16], rax

    mov rcx, [rbp - BT_H]
    mov rdi, [rcx + BHandle.unused]
    mov qword [rcx + BHandle.unused], 0
    mov qword [rcx + BHandle.unused_len], 0
    test rdi, rdi
    jz .bt_done
    call ap_free
.bt_done:
    mov rax, [rbp - BT_TUP]
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret

.bt_mem:
    RAISE exc_ValueError_type, "Out of memory"
.bt_bad_handle:
    RAISE exc_ValueError_type, "invalid stream handle"
.bt_nargs:
    RAISE exc_TypeError_type, "_bz2core: wrong number of arguments"
END_FUNC bc_stream_state

;; ============================================================================
;; bc_bytes_or_empty(rdi = data or 0, rsi = length) -> rax = a bytes object
;; ============================================================================
DEF_FUNC_LOCAL bc_bytes_or_empty
    test rdi, rdi
    jnz .bbe_copy
    xor edi, edi
    leave
    jmp bytes_new
.bbe_copy:
    leave
    jmp bytes_from_data
END_FUNC bc_bytes_or_empty

;; ============================================================================
;; _bz2core.stream_free(handle) -> None
;;
;; Ends the libbzip2 stream and gives the slot back.  lib/_bz2.py calls it
;; from __del__: a compressor's block buffer is 900 KB at level 9, which a
;; loop over a thousand files would notice.
;; ============================================================================
BR_H     equ 8
BR_IDX   equ 16
BR_FRAME equ 32             ; + 0 pushes = 32, 16-aligned
DEF_FUNC bc_stream_free, BR_FRAME
    cmp rsi, 1
    jne .br_nargs
    xor esi, esi
    call bc_arg_int
    mov [rbp - BR_IDX], rax
    mov rdi, rax
    call bc_handle_at
    test rax, rax
    jz .br_done
    mov [rbp - BR_H], rax

    cmp qword [rax + BHandle.ended], 0
    jne .br_ended
    mov qword [rax + BHandle.ended], 1
    lea rdi, [rax + BHandle.bs]
    cmp qword [rax + BHandle.mode], BC_COMPRESS
    jne .br_end_decompress
    call BZ2_bzCompressEnd wrt ..plt
    jmp .br_ended
.br_end_decompress:
    call BZ2_bzDecompressEnd wrt ..plt
.br_ended:

    mov rax, [rbp - BR_H]
    mov rdi, [rax + BHandle.tail]
    test rdi, rdi
    jz .br_no_tail
    call ap_free
.br_no_tail:
    mov rax, [rbp - BR_H]
    mov rdi, [rax + BHandle.unused]
    test rdi, rdi
    jz .br_no_unused
    call ap_free
.br_no_unused:
    mov rax, [rbp - BR_H]
    mov qword [rax + BHandle.magic], 0
    mov rcx, [rel bc_handles]
    mov rdx, [rbp - BR_IDX]
    mov qword [rcx + rdx*8], 0
    mov rdi, rax
    call ap_free

.br_done:
    RET_NONE
    leave
    V_PACK rax, rdx
    ret
.br_nargs:
    RAISE exc_TypeError_type, "_bz2core: wrong number of arguments"
END_FUNC bc_stream_free

;; ============================================================================
;; bz2_module_create() -> rax = the module object
;; ============================================================================
BMC_FRAME equ 32            ; + 2 pushes = 48, 16-aligned
DEF_FUNC bz2_module_create, BMC_FRAME
    push rbx
    push r12
    call dict_new
    mov r12, rax                ; MODULE_ADD_FUNC reads the dict from r12

    MODULE_ADD_FUNC bc_stream_new,   bc_n_stream_new
    MODULE_ADD_FUNC bc_stream_feed,  bc_n_stream_feed
    MODULE_ADD_FUNC bc_stream_state, bc_n_stream_state
    MODULE_ADD_FUNC bc_stream_free,  bc_n_stream_free

    lea rdi, [rel bc_name]
    call str_from_cstr_heap
    mov rbx, rax
    mov rdi, rax
    mov rsi, r12
    call module_new
    mov rbx, rax
    mov rdi, r12
    call obj_decref
    mov rax, rbx
    pop r12
    pop rbx
    leave
    ret
END_FUNC bz2_module_create

section .rodata
bc_name:           db "_bz2core", 0
bc_n_stream_new:   db "stream_new", 0
bc_n_stream_feed:  db "stream_feed", 0
bc_n_stream_state: db "stream_state", 0
bc_n_stream_free:  db "stream_free", 0
bc_e_notbytes:     db `a bytes-like object is required, not '\x01'`, 0
