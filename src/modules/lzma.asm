; lzma.asm - the `_lzmacore` module: liblzma's lzma_stream, and nothing else.
;
; The same split src/modules/zlib.asm's header states as a contract, and the
; one src/modules/bz2.asm follows.  What is genuinely C lives here -- the
; lzma_stream, the filter chain and its option structs, the output buffer that
; grows while the codec writes into it, the handle table -- and everything a
; Python program sees is lib/_lzma.py: the LZMACompressor and LZMADecompressor
; objects, the constants, LZMAError, the filter DICTS and every default.  So
; every function here takes a fixed number of positional arguments and answers
; with a bytes, an int or a tuple.
;
; A filter chain arrives as a list of TUPLES OF INTS rather than as the dicts
; a caller writes, because the names, the defaults and the per-filter error
; wordings are Python's business and the struct layout is this file's.  The
; shapes are fixed and lib/_lzma.py builds them:
;
;   LZMA1 / LZMA2  (id, preset, dict_size, lc, lp, pb, mode, nice_len, mf,
;                   depth) -- every field after `preset` is -1 for "leave the
;                   preset's value", which is never a legal uint32 and so can
;                   never collide with one
;   DELTA          (id, dist)
;   X86 and the other BCJ filters   (id, start_offset)
;
; A handle is an INDEX into lc_handles, not a pointer.  A pointer would be an
; integer a Python program could forge and this module would dereference; an
; index is bounds-checked and a freed slot reads back as 0.

%include "macros.inc"
%include "object.inc"

ASM_INIT

extern none_singleton
extern dict_new
extern dict_set
extern module_new
extern str_from_cstr_heap
extern obj_decref
extern obj_dealloc
extern int_from_i64
extern builtin_func_new
extern bytes_new
extern bytes_from_data
extern bytes_type
extern bytearray_type
extern memoryview_type
extern list_type
extern tuple_type
extern tuple_new
extern ap_malloc
extern ap_realloc
extern ap_free
extern ap_memcpy
extern ap_memset
extern obj_as_index
extern set_type_error_with_name
extern exc_TypeError_type
extern exc_ValueError_type
extern exc_BufferError_type
extern set_exception
extern bool_true
extern bool_false

extern lzma_code
extern lzma_end
extern lzma_easy_encoder
extern lzma_stream_encoder
extern lzma_alone_encoder
extern lzma_raw_encoder
extern lzma_auto_decoder
extern lzma_stream_decoder
extern lzma_alone_decoder
extern lzma_raw_decoder
extern lzma_lzma_preset
extern lzma_check_is_supported
extern lzma_get_check
extern lzma_properties_size
extern lzma_properties_encode
extern lzma_properties_decode
extern free

LC_MAGIC       equ 0x4C5A4D41      ; "LZMA"
LC_INITIAL_OUT equ 8192

; The formats, as lib/_lzma.py spells them.
LC_FORMAT_AUTO  equ 0
LC_FORMAT_XZ    equ 1
LC_FORMAT_ALONE equ 2
LC_FORMAT_RAW   equ 3

LZMA_RUN        equ 0
LZMA_FINISH     equ 3

LZMA_OK         equ 0
LZMA_STREAM_END equ 1
LZMA_NO_CHECK   equ 2
LZMA_GET_CHECK  equ 4
LZMA_BUF_ERROR  equ 10

LZMA_CHECK_CRC64   equ 4
LZMA_CHECK_UNKNOWN equ 16          ; LZMA_CHECK_ID_MAX + 1

LZMA_PRESET_DEFAULT equ 6
LZMA_DELTA_TYPE_BYTE equ 0
LZMA_FILTERS_MAX equ 4

; LZMA_TELL_ANY_CHECK | LZMA_TELL_NO_CHECK, which is what tells the decoder to
; stop and report the check so `LZMADecompressor.check` can answer.
LC_DECODER_FLAGS equ 0x4 | 0x1

; liblzma's lzma_stream, taken from the header with offsetof.  avail_in and
; avail_out are size_t here, not the 32-bit counters bzip2 and zlib use, so
; nothing has to be fed in chunks.
struc LzStream
    .next_in:   resq 1  ; +0
    .avail_in:  resq 1  ; +8
    .total_in:  resq 1  ; +16
    .next_out:  resq 1  ; +24
    .avail_out: resq 1  ; +32
    .total_out: resq 1  ; +40
    .allocator: resq 1  ; +48
    .internal:  resq 1  ; +56
    .reserved:  resb 72 ; +64, through to 136
endstruc

struc LzFilter
    .id:      resq 1
    .options: resq 1
endstruc                ; sizeof = 16

LC_OPTS_SIZE equ 112    ; sizeof(lzma_options_lzma), the largest of the three

struc LzOptions        ; lzma_options_lzma; the delta and bcj structs overlay
    .dict_size:        resd 1  ; +0
    .lopad0:           resd 1  ; +4
    .preset_dict:      resq 1  ; +8
    .preset_dict_size: resd 1  ; +16
    .lc:               resd 1  ; +20
    .lp:               resd 1  ; +24
    .pb:               resd 1  ; +28
    .mode:             resd 1  ; +32
    .nice_len:         resd 1  ; +36
    .mf:               resd 1  ; +40
    .depth:            resd 1  ; +44
endstruc

; lzma_options_delta: type at +0, dist at +4.
LC_DELTA_TYPE equ 0
LC_DELTA_DIST equ 4
; lzma_options_bcj: start_offset at +0.
LC_BCJ_START  equ 0

struc LHandle
    ; The lzma_stream first, so it inherits the allocator's alignment, for the
    ; reason zlib.asm's ZHandle gives.
    .ls:         resb LzStream_size
    .filters:    resb (LZMA_FILTERS_MAX + 1) * 16
    .opts:       resb LZMA_FILTERS_MAX * LC_OPTS_SIZE
    .nfilters:   resq 1
    .mode:       resq 1  ; 0 = encode, 1 = decode
    .eof:        resq 1
    .ended:      resq 1
    .check:      resq 1  ; what lzma_get_check reported, or CHECK_UNKNOWN
    .needs_input: resq 1 ; what CPython's rule below makes it
    .tail:       resq 1
    .tail_len:   resq 1
    .unused:     resq 1
    .unused_len: resq 1
    .magic:      resq 1
endstruc

LC_ENCODE equ 0
LC_DECODE equ 1

section .bss
lc_handles:    resq 1
lc_handle_n:   resq 1
lc_handle_cap: resq 1

section .text

;; ============================================================================
;; lc_handle_at(rdi = handle index) -> rax = LHandle*, or 0
;;
;; Bounds-checked and magic-checked, because the index came from Python.
;; ============================================================================
DEF_FUNC_BARE lc_handle_at
    xor eax, eax
    test rdi, rdi
    js .lha_no
    cmp rdi, [rel lc_handle_n]
    jae .lha_no
    mov rax, [rel lc_handles]
    test rax, rax
    jz .lha_no
    mov rax, [rax + rdi*8]
    test rax, rax
    jz .lha_no
    cmp qword [rax + LHandle.magic], LC_MAGIC
    je .lha_out
    xor eax, eax
.lha_out:
.lha_no:
    ret
END_FUNC lc_handle_at

;; ============================================================================
;; lc_arg_int(rdi = args, rsi = index) -> rax = the int
;; Fails: -1
;; ============================================================================
DEF_FUNC_BARE lc_arg_int
    mov rdi, [rdi + rsi*8]
    V_UNPACK rdi, rdx
    sub rsp, 8                  ; a call, so the refusal can be seen
    call obj_as_index           ; err: its -1 and its exception are this one's
    add rsp, 8
    ret
END_FUNC lc_arg_int

;; ============================================================================
;; lc_item_int(rdi = a tuple or list, rsi = index) -> rax = the int
;; Fails: -1
;;
;; The same, reading out of a sequence rather than out of the argument array.
;; ============================================================================
DEF_FUNC_BARE lc_item_int
    mov rax, [rdi + PyListObject.ob_type]
    lea rcx, [rel list_type]
    cmp rax, rcx
    je .lii_list
    mov rdi, [rdi + PyTupleObject.ob_item]
    jmp .lii_have
.lii_list:
    mov rdi, [rdi + PyListObject.ob_item]
.lii_have:
    mov rdi, [rdi + rsi*8]
    V_UNPACK rdi, rdx
    sub rsp, 8                  ; a call, so the refusal can be seen
    call obj_as_index           ; err: its -1 and its exception are this one's
    add rsp, 8
    ret
END_FUNC lc_item_int

;; ============================================================================
;; lc_seq_info(rdi = a Value) -> rax = the item array, rdx = the length, or
;;   rax = 0 when it is neither a list nor a tuple
;; ============================================================================
DEF_FUNC_BARE lc_seq_info
    V_TEST_PTR rdi, rax
    ja .lsi_no
    test rdi, rdi
    jz .lsi_no
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel list_type]
    cmp rax, rcx
    je .lsi_list
    lea rcx, [rel tuple_type]
    cmp rax, rcx
    jne .lsi_no
    mov rdx, [rdi + PyTupleObject.ob_size]
    mov rax, [rdi + PyTupleObject.ob_item]      ; a POINTER field, not inline
    ret
.lsi_list:
    mov rdx, [rdi + PyListObject.ob_size]
    mov rax, [rdi + PyListObject.ob_item]
    ret
.lsi_no:
    xor eax, eax
    xor edx, edx
    ret
END_FUNC lc_seq_info

;; ============================================================================
;; lc_buffer(rdi = a Value) -> rax = data pointer, rdx = length, rax = 0 when
;;   it is not a buffer at all
;; Fails: 0?
;;
;; Two zeroes: with nothing pending the caller words the TypeError; with the
;; BufferError pending -- a memoryview that is not contiguous -- it propagates.
;;
;; bytes, bytearray and a CONTIGUOUS memoryview -- LZMAFile.write hands one
;; on rather than copying what it was given.
;; ============================================================================
DEF_FUNC_BARE lc_buffer
    V_TEST_PTR rdi, rax
    ja .lb_no
    test rdi, rdi
    jz .lb_no
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel bytes_type]
    cmp rax, rcx
    je .lb_bytes
    lea rcx, [rel bytearray_type]
    cmp rax, rcx
    je .lb_bytearray
    lea rcx, [rel memoryview_type]
    cmp rax, rcx
    jne .lb_no
    mov rax, [rdi + PyMemoryViewObject.mv_buf]
    test rax, rax
    jz .lb_no
    cmp qword [rdi + PyMemoryViewObject.mv_stride], 1
    jne .lb_strided
    mov rdx, [rdi + PyMemoryViewObject.mv_len]
    ret
.lb_bytearray:
    mov rdx, [rdi + PyByteArrayObject.ob_size]
    mov rax, [rdi + PyByteArrayObject.ob_bytes]
    ret
.lb_bytes:
    mov rdx, [rdi + PyBytesObject.ob_size]
    lea rax, [rdi + PyBytesObject.data]
    ret
.lb_strided:
    sub rsp, 8                  ; a bare function: realign for the call
    SET_EXC exc_BufferError_type, "memoryview: underlying buffer is not C-contiguous"
    add rsp, 8
.lb_no:
    xor eax, eax
    xor edx, edx
    ret
END_FUNC lc_buffer

;; ============================================================================
;; lc_set_lz(rdi = the liblzma return code) -> rax = 0, with the error pending
;;
;; The sentence CPython's _lzmamodule.c uses for that code, raised as a
;; ValueError because a module written in assembly cannot raise a class
;; defined in Python.  lib/_lzma.py maps the sentence back to LZMAError, or to
;; MemoryError for the one code CPython reports that way; the mapping is by
;; exact text and both halves say so.
;; ============================================================================
DEF_FUNC lc_set_lz
    cmp edi, 3
    je .lrz_check
    cmp edi, 5
    je .lrz_mem
    cmp edi, 6
    je .lrz_memlimit
    cmp edi, 7
    je .lrz_format
    cmp edi, 8
    je .lrz_options
    cmp edi, 9
    je .lrz_data
    cmp edi, 10
    je .lrz_buf
    FAIL exc_ValueError_type, "Internal error", .lrz_out
.lrz_check:
    FAIL exc_ValueError_type, "Unsupported integrity check", .lrz_out
.lrz_mem:
    FAIL exc_ValueError_type, "Out of memory", .lrz_out
.lrz_memlimit:
    FAIL exc_ValueError_type, "Memory usage limit exceeded", .lrz_out
.lrz_format:
    FAIL exc_ValueError_type, "Input format not supported by decoder", .lrz_out
.lrz_options:
    FAIL exc_ValueError_type, "Invalid or unsupported options", .lrz_out
.lrz_data:
    FAIL exc_ValueError_type, "Corrupt input data", .lrz_out
.lrz_buf:
    SET_EXC exc_ValueError_type, "Insufficient buffer space"
.lrz_out:
    xor eax, eax
    leave
    ret
END_FUNC lc_set_lz

;; ============================================================================
;; lc_slot(rdi = LHandle*) -> rax = the handle index, as a Value
;; Fails: 0
;;
;; Files the stream in the table, reusing a slot a free gave back.  When the
;; table cannot grow the stream is still the caller's to end and free.
;; ============================================================================
LS_CAP   equ 16
LS_FRAME equ 24             ; + 1 push = 32, 16-aligned
DEF_FUNC_LOCAL lc_slot, LS_FRAME
    push rbx
    mov rbx, rdi
    xor ecx, ecx
    mov rdx, [rel lc_handles]
    test rdx, rdx
    jz .ls_grow
.ls_scan:
    cmp rcx, [rel lc_handle_n]
    jae .ls_grow
    cmp qword [rdx + rcx*8], 0
    je .ls_have
    inc rcx
    jmp .ls_scan

.ls_grow:
    mov rax, [rel lc_handle_n]
    cmp rax, [rel lc_handle_cap]
    jb .ls_no_grow
    mov rsi, [rel lc_handle_cap]
    test rsi, rsi
    jnz .ls_double
    mov esi, 8
    jmp .ls_realloc
.ls_double:
    add rsi, rsi
.ls_realloc:
    mov [rbp - LS_CAP], rsi
    shl rsi, 3
    mov rdi, [rel lc_handles]
    call ap_realloc
    test rax, rax
    jz .ls_oom
    mov [rel lc_handles], rax
    mov rcx, [rbp - LS_CAP]
    mov [rel lc_handle_cap], rcx
.ls_no_grow:
    mov rcx, [rel lc_handle_n]
    inc qword [rel lc_handle_n]
    mov rdx, [rel lc_handles]

.ls_have:
    mov [rdx + rcx*8], rbx
    mov rdi, rcx
    call int_from_i64
    V_PACK rax, rdx
    pop rbx
    leave
    ret

.ls_oom:
    SET_EXC exc_ValueError_type, "Out of memory"
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC lc_slot

;; ============================================================================
;; lc_fill_options(rdi = the filter's int tuple, rsi = an LzOptions* to fill,
;;                 rdx = the filter id)
;;   -> rax = the options pointer to hand liblzma
;; Fails: 0
;;
;; Turns one of the three fixed tuple shapes into the struct liblzma wants.
;; The LZMA arm fills the whole struct from the preset FIRST and then applies
;; the overrides, which is the order CPython uses and the only one that gives
;; a caller who names two fields the preset's values for the other seven.
;; A field that is not an int, and a preset liblzma refuses, are the failures.
;; ============================================================================
LFO_TUP   equ 8
LFO_OPT   equ 16
LFO_ID    equ 24
LFO_FRAME equ 32            ; + 2 pushes = 48, 16-aligned
DEF_FUNC_LOCAL lc_fill_options, LFO_FRAME
    push rbx
    push r12
    mov [rbp - LFO_TUP], rdi
    mov [rbp - LFO_OPT], rsi
    mov [rbp - LFO_ID], rdx

    mov rax, rdx
    mov rcx, 0x4000000000000001      ; LZMA_FILTER_LZMA1
    cmp rax, rcx
    je .lfo_lzma
    cmp rax, 0x21                    ; LZMA_FILTER_LZMA2
    je .lfo_lzma
    cmp rax, 3                       ; LZMA_FILTER_DELTA
    je .lfo_delta
    ; Everything else is a BCJ filter, which lib/_lzma.py has already
    ; restricted to the six ids liblzma knows.
    mov rdi, [rbp - LFO_TUP]
    mov esi, 1
    call lc_item_int
    ERR_M1 .lfo_fail
    mov rcx, [rbp - LFO_OPT]
    mov [rcx + LC_BCJ_START], eax
    mov rax, rcx
    jmp .lfo_done

.lfo_delta:
    mov rdi, [rbp - LFO_TUP]
    mov esi, 1
    call lc_item_int
    ERR_M1 .lfo_fail
    mov rcx, [rbp - LFO_OPT]
    mov dword [rcx + LC_DELTA_TYPE], LZMA_DELTA_TYPE_BYTE
    mov [rcx + LC_DELTA_DIST], eax
    mov rax, rcx
    jmp .lfo_done

.lfo_lzma:
    mov rdi, [rbp - LFO_TUP]
    mov esi, 1
    call lc_item_int
    ERR_M1 .lfo_fail
    mov r12, rax                     ; the preset
    mov rdi, [rbp - LFO_OPT]
    mov esi, r12d
    call lzma_lzma_preset wrt ..plt
    test eax, eax
    jnz .lfo_bad_preset

    ; The eight overrides, each -1 for "leave the preset's value".  The order
    ; is the tuple's, which is the order CPython's optnames list has.
    mov ebx, 2
.lfo_field:
    cmp rbx, 10
    jae .lfo_lzma_done
    mov rdi, [rbp - LFO_TUP]
    mov rsi, rbx
    call lc_item_int
    ERR_M1 .lfo_fail
    test rax, rax
    js .lfo_next                     ; -1: not given
    mov rcx, [rbp - LFO_OPT]
    lea rdx, [rel lc_lzma_offset_bytes]
    movzx edx, byte [rdx + rbx - 2]
    mov [rcx + rdx], eax
.lfo_next:
    inc rbx
    jmp .lfo_field
.lfo_lzma_done:
    mov rax, [rbp - LFO_OPT]

.lfo_done:
    pop r12
    pop rbx
    leave
    ret

.lfo_bad_preset:
    SET_EXC exc_ValueError_type, "Invalid compression preset"
.lfo_fail:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
END_FUNC lc_fill_options

;; ============================================================================
;; lc_build_filters(rdi = LHandle*, rsi = the filters Value)
;;   -> rax = the filter array, or 0 when the Value is None
;; Fails: 0?
;;
;; Fills the handle's own filter array and option blocks, so they outlive the
;; call that hands them to liblzma.  A chain that is not a sequence of tuples,
;; or is longer than liblzma's four, is refused; nothing here is allocated, so
;; the handle is all the caller has to free.
;; ============================================================================
LBF_H     equ 8
LBF_ITEMS equ 16
LBF_N     equ 24
LBF_I     equ 32
LBF_FRAME equ 48            ; + 1 push = 56; a second push makes it 64
DEF_FUNC_LOCAL lc_build_filters, LBF_FRAME
    push rbx
    push r12
    mov [rbp - LBF_H], rdi
    mov rdi, rsi
    IS_NONE rdi, rcx
    je .lbf_none
    call lc_seq_info
    test rax, rax
    jz .lbf_type
    mov [rbp - LBF_ITEMS], rax
    mov [rbp - LBF_N], rdx
    ; An EMPTY chain is not refused here: liblzma calls it an internal error
    ; and CPython lets it, so the terminator alone is what gets built.
    cmp rdx, LZMA_FILTERS_MAX
    ja .lbf_too_many

    mov qword [rbp - LBF_I], 0
.lbf_loop:
    mov rbx, [rbp - LBF_I]
    cmp rbx, [rbp - LBF_N]
    jae .lbf_terminate
    mov rax, [rbp - LBF_ITEMS]
    mov rdi, [rax + rbx*8]
    call lc_seq_info
    test rax, rax
    jz .lbf_type
    test rdx, rdx
    jz .lbf_type
    mov rax, [rbp - LBF_ITEMS]
    mov r12, [rax + rbx*8]          ; the filter's own tuple

    mov rdi, r12
    xor esi, esi
    call lc_item_int                ; the id
    ERR_M1 .lbf_fail
    mov rcx, [rbp - LBF_H]
    lea rcx, [rcx + LHandle.filters]
    mov rdx, rbx
    shl rdx, 4                      ; sizeof(lzma_filter); x86 scales by 8 at most
    add rcx, rdx
    mov [rcx + LzFilter.id], rax

    push rax
    sub rsp, 8
    mov rdx, rax
    mov rdi, r12
    mov rsi, [rbp - LBF_H]
    lea rsi, [rsi + LHandle.opts]
    mov rax, LC_OPTS_SIZE
    imul rax, rbx
    add rsi, rax
    call lc_fill_options
    ERR_NULL .lbf_fail_pushed
    add rsp, 8
    pop rcx
    mov rcx, [rbp - LBF_H]
    lea rcx, [rcx + LHandle.filters]
    mov rdx, [rbp - LBF_I]
    shl rdx, 4
    add rcx, rdx
    mov [rcx + LzFilter.options], rax

    inc qword [rbp - LBF_I]
    jmp .lbf_loop

.lbf_terminate:
    mov rcx, [rbp - LBF_H]
    mov rdx, [rbp - LBF_N]
    mov [rcx + LHandle.nfilters], rdx
    lea rcx, [rcx + LHandle.filters]
    mov rax, rdx
    shl rax, 4
    add rax, rcx                    ; the terminator's slot
    mov rdx, -1                     ; LZMA_VLI_UNKNOWN
    mov [rax + LzFilter.id], rdx
    mov qword [rax + LzFilter.options], 0
    mov rax, rcx
    pop r12
    pop rbx
    leave
    ret

.lbf_none:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret

.lbf_too_many:
    FAIL exc_ValueError_type, "Filter chain is too long", .lbf_fail
.lbf_type:
    FAIL exc_TypeError_type, "Filter specifier must be a sequence of tuples", .lbf_fail
.lbf_fail_pushed:
    add rsp, 16                 ; the id and its pad, parked across the call
.lbf_fail:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
END_FUNC lc_build_filters

;; ============================================================================
;; lc_alloc_handle(rdi = mode) -> rax = a zeroed LHandle*
;; Fails: 0
;;
;; lzma_stream's initialiser is all zeros, which is what makes ap_memset the
;; whole of it.
;; ============================================================================
LAH_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
DEF_FUNC_LOCAL lc_alloc_handle, LAH_FRAME
    push rdi
    sub rsp, 8
    mov edi, LHandle_size
    call ap_malloc
    add rsp, 8
    pop rdi
    test rax, rax
    jz .lah_mem
    push rdi
    push rax
    mov rdi, rax
    xor esi, esi
    mov edx, LHandle_size
    call ap_memset
    pop rax
    pop rdi
    mov qword [rax + LHandle.magic], LC_MAGIC
    mov [rax + LHandle.mode], rdi
    mov qword [rax + LHandle.check], LZMA_CHECK_UNKNOWN
    mov qword [rax + LHandle.needs_input], 1
    leave
    ret
.lah_mem:
    SET_EXC exc_ValueError_type, "Out of memory"
    leave                       ; set_exception answered 0
    ret
END_FUNC lc_alloc_handle

;; ============================================================================
;; _lzmacore.encoder(format, check, preset, filters) -> int handle
;;
;; The four ways liblzma builds an encoder, chosen exactly as CPython chooses
;; them: a preset alone is lzma_easy_encoder, a chain is lzma_stream_encoder,
;; the .lzma container is lzma_alone_encoder (and takes ONE LZMA1 filter, or a
;; preset), and FORMAT_RAW is lzma_raw_encoder and insists on a chain.
;; ============================================================================
LE_H      equ 8
LE_FORMAT equ 16
LE_CHECK  equ 24
LE_PRESET equ 32
LE_FILTER equ 40            ; the built array, or 0
LE_ARGS   equ 48
LE_FRAME  equ 64            ; + 0 pushes = 64, 16-aligned
DEF_FUNC lc_encoder, LE_FRAME
    cmp rsi, 4
    jne .le_nargs
    mov [rbp - LE_ARGS], rdi
    xor esi, esi
    call lc_arg_int
    ERR_M1 .le_fail
    mov [rbp - LE_FORMAT], rax
    mov rdi, [rbp - LE_ARGS]
    mov esi, 1
    call lc_arg_int
    ERR_M1 .le_fail
    mov [rbp - LE_CHECK], rax
    mov rdi, [rbp - LE_ARGS]
    mov esi, 2
    call lc_arg_int
    ERR_M1 .le_fail
    mov [rbp - LE_PRESET], rax

    mov edi, LC_ENCODE
    call lc_alloc_handle
    ERR_NULL .le_fail
    mov [rbp - LE_H], rax

    ; From here every refusal leaves through .le_fail_handle: the handle is
    ; this call's until lc_slot has filed it.
    mov rdi, rax
    mov rcx, [rbp - LE_ARGS]
    mov rsi, [rcx + 24]
    call lc_build_filters
    ERR_PENDING .le_fail_handle
    mov [rbp - LE_FILTER], rax

    mov rax, [rbp - LE_FORMAT]
    cmp rax, LC_FORMAT_XZ
    je .le_xz
    cmp rax, LC_FORMAT_ALONE
    je .le_alone
    cmp rax, LC_FORMAT_RAW
    je .le_raw
    FAIL exc_ValueError_type, "Invalid container format", .le_fail_handle

.le_xz:
    mov rdi, [rbp - LE_H]
    cmp qword [rbp - LE_FILTER], 0
    jne .le_xz_filters
    mov esi, [rbp - LE_PRESET]
    mov edx, [rbp - LE_CHECK]
    call lzma_easy_encoder wrt ..plt
    jmp .le_check
.le_xz_filters:
    mov rsi, [rbp - LE_FILTER]
    mov edx, [rbp - LE_CHECK]
    call lzma_stream_encoder wrt ..plt
    jmp .le_check

.le_alone:
    cmp qword [rbp - LE_FILTER], 0
    jne .le_alone_filters
    ; No chain: build one LZMA1 option block from the preset.
    mov rdi, [rbp - LE_H]
    lea rdi, [rdi + LHandle.opts]
    mov esi, [rbp - LE_PRESET]
    call lzma_lzma_preset wrt ..plt
    test eax, eax
    jnz .le_bad_preset
    mov rdi, [rbp - LE_H]
    lea rsi, [rdi + LHandle.opts]
    call lzma_alone_encoder wrt ..plt
    jmp .le_check
.le_alone_filters:
    ; A chain: it has to be exactly one LZMA1 filter, which is the only thing
    ; the .lzma container can hold.
    mov rcx, [rbp - LE_H]
    cmp qword [rcx + LHandle.nfilters], 1
    jne .le_alone_chain
    lea rdx, [rcx + LHandle.filters]
    mov rax, [rdx + LzFilter.id]
    mov rcx, 0x4000000000000001
    cmp rax, rcx
    jne .le_alone_chain
    mov rdi, [rbp - LE_H]
    mov rsi, [rdx + LzFilter.options]
    call lzma_alone_encoder wrt ..plt
    jmp .le_check

.le_raw:
    cmp qword [rbp - LE_FILTER], 0
    je .le_raw_nofilters
    mov rdi, [rbp - LE_H]
    mov rsi, [rbp - LE_FILTER]
    call lzma_raw_encoder wrt ..plt

.le_check:
    test eax, eax
    jnz .le_failed
    mov rdi, [rbp - LE_H]
    call lc_slot
    ERR_NULL .le_no_slot
    leave
    ret

.le_no_slot:
    ; The encoder was built and nothing will ever name it: end it, so the
    ; dictionary goes back, then free the handle.
    mov rdi, [rbp - LE_H]
    lea rdi, [rdi + LHandle.ls]
    call lzma_end wrt ..plt
    jmp .le_fail_handle
.le_failed:
    mov edi, eax
    call lc_set_lz
    jmp .le_fail_handle
.le_bad_preset:
    FAIL exc_ValueError_type, "Invalid compression preset", .le_fail_handle
.le_alone_chain:
    FAIL exc_ValueError_type, "Invalid filter chain for FORMAT_ALONE - must be a single LZMA1 filter", .le_fail_handle
.le_raw_nofilters:
    FAIL exc_ValueError_type, "Must specify filters for FORMAT_RAW", .le_fail_handle
.le_nargs:
    FAIL exc_TypeError_type, "_lzmacore: wrong number of arguments", .le_fail
.le_fail_handle:
    mov rdi, [rbp - LE_H]
    call ap_free
.le_fail:
    xor eax, eax
    leave
    ret
END_FUNC lc_encoder

;; ============================================================================
;; _lzmacore.decoder(format, memlimit, filters) -> int handle
;;
;; memlimit of -1 is "no limit", which liblzma spells as UINT64_MAX.  The
;; decoder flags are CPython's: TELL_ANY_CHECK and TELL_NO_CHECK, which are
;; what make lzma_code stop and report the check so `.check` can answer.
;; ============================================================================
LD_H      equ 8
LD_FORMAT equ 16
LD_MEM    equ 24
LD_FILTER equ 32
LD_ARGS   equ 40
LD_FRAME  equ 48            ; + 0 pushes = 48, 16-aligned
DEF_FUNC lc_decoder, LD_FRAME
    cmp rsi, 3
    jne .ld_nargs
    mov [rbp - LD_ARGS], rdi
    xor esi, esi
    call lc_arg_int
    ERR_M1 .ld_fail
    mov [rbp - LD_FORMAT], rax
    mov rdi, [rbp - LD_ARGS]
    mov esi, 1
    call lc_arg_int
    ERR_M1 .ld_fail
    test rax, rax
    jns .ld_have_mem
    mov rax, -1                 ; UINT64_MAX: no limit
.ld_have_mem:
    mov [rbp - LD_MEM], rax

    mov edi, LC_DECODE
    call lc_alloc_handle
    ERR_NULL .ld_fail
    mov [rbp - LD_H], rax

    ; As in the encoder: the handle is this call's until lc_slot files it.
    mov rdi, rax
    mov rcx, [rbp - LD_ARGS]
    mov rsi, [rcx + 16]
    call lc_build_filters
    ERR_PENDING .ld_fail_handle
    mov [rbp - LD_FILTER], rax

    mov rax, [rbp - LD_FORMAT]
    cmp rax, LC_FORMAT_AUTO
    je .ld_auto
    cmp rax, LC_FORMAT_XZ
    je .ld_xz
    cmp rax, LC_FORMAT_ALONE
    je .ld_alone
    cmp rax, LC_FORMAT_RAW
    je .ld_raw
    FAIL exc_ValueError_type, "Invalid container format", .ld_fail_handle

.ld_auto:
    mov rdi, [rbp - LD_H]
    mov rsi, [rbp - LD_MEM]
    mov edx, LC_DECODER_FLAGS
    call lzma_auto_decoder wrt ..plt
    jmp .ld_check
.ld_xz:
    mov rdi, [rbp - LD_H]
    mov rsi, [rbp - LD_MEM]
    mov edx, LC_DECODER_FLAGS
    call lzma_stream_decoder wrt ..plt
    jmp .ld_check
.ld_alone:
    mov rdi, [rbp - LD_H]
    mov rsi, [rbp - LD_MEM]
    call lzma_alone_decoder wrt ..plt
    jmp .ld_check
.ld_raw:
    cmp qword [rbp - LD_FILTER], 0
    je .ld_raw_nofilters
    mov rdi, [rbp - LD_H]
    mov rsi, [rbp - LD_FILTER]
    call lzma_raw_decoder wrt ..plt

.ld_check:
    test eax, eax
    jnz .ld_failed
    mov rdi, [rbp - LD_H]
    call lc_slot
    ERR_NULL .ld_no_slot
    leave
    ret

.ld_no_slot:
    mov rdi, [rbp - LD_H]
    lea rdi, [rdi + LHandle.ls]
    call lzma_end wrt ..plt
    jmp .ld_fail_handle
.ld_failed:
    mov edi, eax
    call lc_set_lz
    jmp .ld_fail_handle
.ld_raw_nofilters:
    FAIL exc_ValueError_type, "Must specify filters for FORMAT_RAW", .ld_fail_handle
.ld_nargs:
    FAIL exc_TypeError_type, "_lzmacore: wrong number of arguments", .ld_fail
.ld_fail_handle:
    mov rdi, [rbp - LD_H]
    call ap_free
.ld_fail:
    xor eax, eax
    leave
    ret
END_FUNC lc_decoder

;; ============================================================================
;; _lzmacore.stream_feed(handle, data, action, max_length) -> bytes
;;
;; Push `data` through the stream and answer everything that came out.  The
;; input is COPIED first, and whatever the last call did not consume is copied
;; in front of it: liblzma keeps next_in pointing into that buffer for the
;; length of the loop, and a bytes handed in from Python is not ours to pin.
;;
;; A max_length of 0 or more caps the output and parks the rest of the input;
;; NEGATIVE means no cap.  Zero is a real cap: `decompress(data, 0)` answers
;; b"" and consumes nothing.
;;
;; LZMA_BUF_ERROR with nothing to read and room to write is not a real error;
;; it is liblzma saying it made no progress, and CPython's loop says the same.
;; ============================================================================
LF_ARGS   equ 8
LF_INBUF  equ 16
LF_INLEN  equ 24
LF_ACTION equ 32
LF_MAX    equ 40
LF_OUT    equ 48
LF_OUTCAP equ 56
LF_OUTLEN equ 64
LF_RES    equ 72
LF_CODE   equ 80
LF_FRAME  equ 96            ; + 2 pushes = 112, 16-aligned
DEF_FUNC lc_stream_feed, LF_FRAME
    push rbx
    push r12
    mov r12, rsp
    and rsp, -16                ; the same precaution zc_stream_feed takes
    cmp rsi, 4
    jne .lf_nargs
    mov [rbp - LF_ARGS], rdi
    mov qword [rbp - LF_INBUF], 0
    mov qword [rbp - LF_OUT], 0

    xor esi, esi
    call lc_arg_int
    ERR_M1 .lf_fail
    mov rdi, rax
    call lc_handle_at
    test rax, rax
    jz .lf_bad_handle
    mov rbx, rax
    cmp qword [rbx + LHandle.ended], 0
    jne .lf_ended

    mov rdi, [rbp - LF_ARGS]
    mov esi, 2
    call lc_arg_int
    ERR_M1 .lf_fail
    mov [rbp - LF_ACTION], rax
    mov rdi, [rbp - LF_ARGS]
    mov esi, 3
    call lc_arg_int
    ERR_M1 .lf_fail
    mov [rbp - LF_MAX], rax

    ; --- the input: the handle's leftover, then what was handed in ---------
    mov rdi, [rbp - LF_ARGS]
    mov rdi, [rdi + 8]
    call lc_buffer
    ERR_PENDING .lf_fail        ; a memoryview that is not contiguous
    test rax, rax
    jnz .lf_have_buf
    jmp .lf_type
.lf_have_buf:
    mov r10, rax
    mov r11, rdx
    mov rax, [rbx + LHandle.tail_len]
    add rax, r11
    mov [rbp - LF_INLEN], rax
    test rax, rax
    jz .lf_input_ready

    push r10
    push r11
    mov rdi, rax
    call ap_malloc
    pop r11
    pop r10
    test rax, rax
    jz .lf_mem
    mov [rbp - LF_INBUF], rax

    mov rdx, [rbx + LHandle.tail_len]
    test rdx, rdx
    jz .lf_copy_new
    push r10
    push r11
    mov rdi, rax
    mov rsi, [rbx + LHandle.tail]
    call ap_memcpy
    pop r11
    pop r10
.lf_copy_new:
    test r11, r11
    jz .lf_input_ready
    mov rdi, [rbp - LF_INBUF]
    add rdi, [rbx + LHandle.tail_len]
    mov rsi, r10
    mov rdx, r11
    call ap_memcpy

.lf_input_ready:
    mov rdi, [rbx + LHandle.tail]
    mov qword [rbx + LHandle.tail], 0
    mov qword [rbx + LHandle.tail_len], 0
    test rdi, rdi
    jz .lf_tail_gone
    call ap_free
.lf_tail_gone:
    mov rax, [rbp - LF_INBUF]
    mov [rbx + LHandle.ls + LzStream.next_in], rax
    mov rax, [rbp - LF_INLEN]
    mov [rbx + LHandle.ls + LzStream.avail_in], rax

    ; --- the output buffer -------------------------------------------------
    mov rdi, LC_INITIAL_OUT
    mov rcx, [rbp - LF_MAX]
    test rcx, rcx
    js .lf_out_size
    cmp rcx, rdi
    jae .lf_out_size
    mov rdi, rcx
    test rdi, rdi
    jnz .lf_out_size
    mov edi, 1                  ; a cap of 0 still needs an allocation
.lf_out_size:
    mov [rbp - LF_OUTCAP], rdi
    call ap_malloc
    test rax, rax
    jz .lf_mem
    mov [rbp - LF_OUT], rax
    mov qword [rbp - LF_OUTLEN], 0

.lf_loop:
    ; The cap, tested before the call so a cap of 0 produces nothing at all.
    mov rcx, [rbp - LF_MAX]
    test rcx, rcx
    js .lf_no_cap
    cmp [rbp - LF_OUTLEN], rcx
    jae .lf_done
.lf_no_cap:
    mov rax, [rbp - LF_OUT]
    add rax, [rbp - LF_OUTLEN]
    mov [rbx + LHandle.ls + LzStream.next_out], rax
    mov rax, [rbp - LF_OUTCAP]
    sub rax, [rbp - LF_OUTLEN]
    mov [rbx + LHandle.ls + LzStream.avail_out], rax

    lea rdi, [rbx + LHandle.ls]
    mov esi, [rbp - LF_ACTION]
    call lzma_code wrt ..plt
    mov [rbp - LF_CODE], rax

    mov rax, [rbx + LHandle.ls + LzStream.next_out]
    sub rax, [rbp - LF_OUT]
    mov [rbp - LF_OUTLEN], rax

    ; BUF_ERROR with nothing to read and room to write is "no progress", not
    ; a failure -- CPython rewrites it to OK for exactly this case.
    mov eax, [rbp - LF_CODE]
    cmp eax, LZMA_BUF_ERROR
    jne .lf_have_code
    cmp qword [rbx + LHandle.ls + LzStream.avail_in], 0
    jne .lf_have_code
    cmp qword [rbx + LHandle.ls + LzStream.avail_out], 0
    je .lf_have_code
    xor eax, eax
    mov [rbp - LF_CODE], rax
.lf_have_code:

    ; The check becomes knowable the moment liblzma says so.
    cmp eax, LZMA_GET_CHECK
    je .lf_get_check
    cmp eax, LZMA_NO_CHECK
    jne .lf_checked
.lf_get_check:
    push rax
    sub rsp, 8
    lea rdi, [rbx + LHandle.ls]
    call lzma_get_check wrt ..plt
    mov [rbx + LHandle.check], rax
    add rsp, 8
    pop rax
.lf_checked:

    cmp eax, LZMA_STREAM_END
    je .lf_stream_end
    cmp eax, LZMA_OK
    je .lf_ok
    cmp eax, LZMA_GET_CHECK
    je .lf_ok
    cmp eax, LZMA_NO_CHECK
    je .lf_ok
    jmp .lf_lzerror

.lf_ok:
    ; A compressor in LZMA_RUN stops when its input is gone; a decompressor
    ; stops when its input is gone AND there is room left over, because a
    ; full output buffer may only mean there is more to come.
    cmp qword [rbx + LHandle.ls + LzStream.avail_out], 0
    jne .lf_room_left

    mov rcx, [rbp - LF_MAX]
    test rcx, rcx
    js .lf_grow
    cmp [rbp - LF_OUTLEN], rcx
    jae .lf_done                ; the cap is reached; park the rest
.lf_grow:
    mov rax, [rbp - LF_OUTCAP]
    add rax, rax
    mov rcx, [rbp - LF_MAX]
    test rcx, rcx
    js .lf_grow_to
    cmp rax, rcx
    jbe .lf_grow_to
    mov rax, rcx
.lf_grow_to:
    mov rdi, [rbp - LF_OUT]
    mov rsi, rax
    push rax
    sub rsp, 8
    call ap_realloc
    add rsp, 8
    pop rcx
    test rax, rax
    jz .lf_mem
    mov [rbp - LF_OUT], rax
    mov [rbp - LF_OUTCAP], rcx
    jmp .lf_loop

.lf_room_left:
    cmp qword [rbx + LHandle.ls + LzStream.avail_in], 0
    je .lf_done
    jmp .lf_loop

.lf_stream_end:
    mov qword [rbx + LHandle.eof], 1
    mov rcx, [rbx + LHandle.ls + LzStream.avail_in]
    test rcx, rcx
    jz .lf_no_tail
    mov rdi, rcx
    push rcx
    sub rsp, 8
    call ap_malloc
    add rsp, 8
    pop rcx
    test rax, rax
    jz .lf_no_tail
    mov [rbx + LHandle.unused], rax
    mov [rbx + LHandle.unused_len], rcx
    mov rdi, rax
    mov rsi, [rbx + LHandle.ls + LzStream.next_in]
    mov rdx, rcx
    call ap_memcpy
    jmp .lf_no_tail

.lf_done:
    mov rcx, [rbx + LHandle.ls + LzStream.avail_in]
    test rcx, rcx
    jz .lf_no_tail
    mov rdi, rcx
    push rcx
    sub rsp, 8
    call ap_malloc
    add rsp, 8
    pop rcx
    test rax, rax
    jz .lf_no_tail
    mov [rbx + LHandle.tail], rax
    mov [rbx + LHandle.tail_len], rcx
    mov rdi, rax
    mov rsi, [rbx + LHandle.ls + LzStream.next_in]
    mov rdx, rcx
    call ap_memcpy

.lf_no_tail:
    ; needs_input, by CPython's rule: false when the stream has ended, false
    ; when input is parked, and false when the output buffer filled exactly at
    ; the cap -- the codec may still be holding bytes that the next call will
    ; emit, and a caller told to read more of the file would stall.
    mov eax, 1
    cmp qword [rbx + LHandle.eof], 0
    jne .lf_no_need
    cmp qword [rbx + LHandle.tail_len], 0
    jne .lf_no_need
    mov rcx, [rbp - LF_MAX]
    test rcx, rcx
    js .lf_set_need
    cmp [rbp - LF_OUTLEN], rcx
    jb .lf_set_need
.lf_no_need:
    xor eax, eax
.lf_set_need:
    mov [rbx + LHandle.needs_input], rax

    mov qword [rbx + LHandle.ls + LzStream.avail_in], 0
    mov qword [rbx + LHandle.ls + LzStream.next_in], 0

    mov rdi, [rbp - LF_OUT]
    mov rsi, [rbp - LF_OUTLEN]
    call bytes_from_data
    test rax, rax
    jz .lf_mem
    mov [rbp - LF_RES], rax
    call lc_release_buffers
    mov rax, [rbp - LF_RES]
    mov edx, TAG_PTR
    mov rsp, r12
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.lf_lzerror:
    mov edi, [rbp - LF_CODE]
    call lc_set_lz
    jmp .lf_fail
.lf_mem:
    FAIL exc_ValueError_type, "Out of memory", .lf_fail
.lf_type:
    lea rdi, [rel lc_e_notbytes]
    mov rsi, [rbp - LF_ARGS]
    mov rsi, [rsi + 8]
    call set_type_error_with_name
    jmp .lf_fail
.lf_bad_handle:
    FAIL exc_ValueError_type, "invalid stream handle", .lf_fail
.lf_ended:
    FAIL exc_ValueError_type, "Internal error", .lf_fail
.lf_nargs:
    ; Before the two buffer slots are initialised, so not through the release.
    FAIL exc_TypeError_type, "_lzmacore: wrong number of arguments", .lf_fail_bare
.lf_fail:
    ; The one error exit: the exception is pending, and the input copy and
    ; the output buffer -- whichever exist -- are this call's to free.
    call lc_release_buffers
.lf_fail_bare:
    xor eax, eax
    mov rsp, r12
    pop r12
    pop rbx
    leave
    ret

;; The two malloc'd buffers this call owns, released on every way out.  A
;; local label rather than a function, because it reads the caller's frame.
lc_release_buffers:
    mov rdi, [rbp - LF_INBUF]
    mov qword [rbp - LF_INBUF], 0
    test rdi, rdi
    jz .lrb_out
    push rax
    sub rsp, 8
    call ap_free
    add rsp, 8
    pop rax
.lrb_out:
    mov rdi, [rbp - LF_OUT]
    mov qword [rbp - LF_OUT], 0
    test rdi, rdi
    jz .lrb_done
    push rax
    sub rsp, 8
    call ap_free
    add rsp, 8
    pop rax
.lrb_done:
    ret
END_FUNC lc_stream_feed

;; ============================================================================
;; _lzmacore.stream_state(handle) -> (eof, needs_input, unused_data, check)
;;
;; The four things an LZMADecompressor reports and cannot compute for itself.
;; unused_data is taken away by this call, because lib/_lzma.py accumulates it
;; into the attribute a caller reads and must not be handed it twice.
;; ============================================================================
LT_H     equ 8
LT_TUP   equ 16
LT_FRAME equ 32             ; + 0 pushes = 32, 16-aligned
DEF_FUNC lc_stream_state, LT_FRAME
    cmp rsi, 1
    jne .lt_nargs
    xor esi, esi
    call lc_arg_int
    ERR_M1 .lt_fail
    mov rdi, rax
    call lc_handle_at
    test rax, rax
    jz .lt_bad_handle
    mov [rbp - LT_H], rax

    mov edi, 4
    call tuple_new
    test rax, rax
    jz .lt_mem
    mov [rbp - LT_TUP], rax

    mov rcx, [rbp - LT_H]
    lea rax, [rel bool_false]
    cmp qword [rcx + LHandle.eof], 0
    je .lt_have_eof
    lea rax, [rel bool_true]
.lt_have_eof:
    INCREF rax
    mov rdx, [rbp - LT_TUP]
    mov rdx, [rdx + PyTupleObject.ob_item]
    mov [rdx], rax

    ; needs_input as the last feed worked it out; see the rule there.
    mov rcx, [rbp - LT_H]
    lea rax, [rel bool_false]
    cmp qword [rcx + LHandle.needs_input], 0
    je .lt_have_needs
    lea rax, [rel bool_true]
.lt_have_needs:
    INCREF rax
    mov rdx, [rbp - LT_TUP]
    mov rdx, [rdx + PyTupleObject.ob_item]
    mov [rdx + 8], rax

    mov rcx, [rbp - LT_H]
    mov rdi, [rcx + LHandle.unused]
    mov rsi, [rcx + LHandle.unused_len]
    call lc_bytes_or_empty
    test rax, rax
    jz .lt_mem_tuple
    mov rdx, [rbp - LT_TUP]
    mov rdx, [rdx + PyTupleObject.ob_item]
    mov [rdx + 16], rax

    mov rcx, [rbp - LT_H]
    mov rdi, [rcx + LHandle.check]
    call int_from_i64
    V_PACK rax, rdx
    mov rdx, [rbp - LT_TUP]
    mov rdx, [rdx + PyTupleObject.ob_item]
    mov [rdx + 24], rax

    mov rcx, [rbp - LT_H]
    mov rdi, [rcx + LHandle.unused]
    mov qword [rcx + LHandle.unused], 0
    mov qword [rcx + LHandle.unused_len], 0
    test rdi, rdi
    jz .lt_done
    call ap_free
.lt_done:
    mov rax, [rbp - LT_TUP]
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret

.lt_mem_tuple:
    mov rdi, [rbp - LT_TUP]     ; two slots filled; the rest are the zeroes
    call obj_decref             ; tuple_new left there
.lt_mem:
    FAIL exc_ValueError_type, "Out of memory", .lt_fail
.lt_bad_handle:
    FAIL exc_ValueError_type, "invalid stream handle", .lt_fail
.lt_nargs:
    SET_EXC exc_TypeError_type, "_lzmacore: wrong number of arguments"
.lt_fail:
    xor eax, eax
    leave
    ret
END_FUNC lc_stream_state

;; ============================================================================
;; lc_bytes_or_empty(rdi = data or 0, rsi = length) -> rax = a bytes object
;; ============================================================================
DEF_FUNC_LOCAL lc_bytes_or_empty
    test rdi, rdi
    jnz .lbe_copy
    xor edi, edi
    leave
    jmp bytes_new
.lbe_copy:
    leave
    jmp bytes_from_data
END_FUNC lc_bytes_or_empty

;; ============================================================================
;; _lzmacore.stream_free(handle) -> None
;;
;; Ends the liblzma stream and gives the slot back.  lib/_lzma.py calls it
;; from __del__: an encoder at preset 9 holds a 64 MB dictionary, which a loop
;; over even a few files would notice.
;; ============================================================================
LR_H     equ 8
LR_IDX   equ 16
LR_FRAME equ 32             ; + 0 pushes = 32, 16-aligned
DEF_FUNC lc_stream_free, LR_FRAME
    cmp rsi, 1
    jne .lr_nargs
    xor esi, esi
    call lc_arg_int
    ERR_M1 .lr_fail
    mov [rbp - LR_IDX], rax
    mov rdi, rax
    call lc_handle_at
    test rax, rax
    jz .lr_done
    mov [rbp - LR_H], rax

    cmp qword [rax + LHandle.ended], 0
    jne .lr_ended
    mov qword [rax + LHandle.ended], 1
    lea rdi, [rax + LHandle.ls]
    call lzma_end wrt ..plt
.lr_ended:

    mov rax, [rbp - LR_H]
    mov rdi, [rax + LHandle.tail]
    test rdi, rdi
    jz .lr_no_tail
    call ap_free
.lr_no_tail:
    mov rax, [rbp - LR_H]
    mov rdi, [rax + LHandle.unused]
    test rdi, rdi
    jz .lr_no_unused
    call ap_free
.lr_no_unused:
    mov rax, [rbp - LR_H]
    mov qword [rax + LHandle.magic], 0
    mov rcx, [rel lc_handles]
    mov rdx, [rbp - LR_IDX]
    mov qword [rcx + rdx*8], 0
    mov rdi, rax
    call ap_free

.lr_done:
    RET_NONE
    leave
    V_PACK rax, rdx
    ret
.lr_nargs:
    SET_EXC exc_TypeError_type, "_lzmacore: wrong number of arguments"
.lr_fail:
    xor eax, eax
    leave
    ret
END_FUNC lc_stream_free

;; ============================================================================
;; _lzmacore.check_is_supported(check_id) -> bool
;; ============================================================================
LK_FRAME equ 16             ; + 0 pushes = 16, 16-aligned
DEF_FUNC lc_check_is_supported, LK_FRAME
    cmp rsi, 1
    jne .lk_nargs
    xor esi, esi
    call lc_arg_int
    ERR_M1 .lk_fail
    mov edi, eax
    call lzma_check_is_supported wrt ..plt
    lea rcx, [rel bool_false]
    test eax, eax
    jz .lk_have
    lea rcx, [rel bool_true]
.lk_have:
    mov rax, rcx
    INCREF rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
.lk_nargs:
    SET_EXC exc_TypeError_type, "_lzmacore: wrong number of arguments"
.lk_fail:
    xor eax, eax
    leave
    ret
END_FUNC lc_check_is_supported

;; ============================================================================
;; _lzmacore.encode_filter_props(filter_tuple) -> bytes
;;
;; The filter's properties as they appear in a raw stream's header: what a
;; caller needs to write one, and what decode_filter_props reads back.  The
;; option struct is built in this frame rather than in a handle, because
;; liblzma copies what it needs before the call returns.
;; ============================================================================
LP_TUP   equ 8
LP_SIZE  equ 16
LP_ID    equ 24
LP_FILT  equ 48                     ; an LzFilter, 16 bytes
LP_OPTS  equ 48 + LC_OPTS_SIZE      ; an LzOptions under it
LP_BUF   equ LP_OPTS + 64           ; the encoded properties
LP_FRAME equ LP_BUF                 ; + 0 pushes; 224, 16-aligned
DEF_FUNC lc_encode_filter_props, LP_FRAME
    cmp rsi, 1
    jne .lp_nargs
    mov rdi, [rdi]
    mov [rbp - LP_TUP], rdi
    call lc_seq_info
    test rax, rax
    jz .lp_type
    test rdx, rdx
    jz .lp_type

    mov rdi, [rbp - LP_TUP]
    xor esi, esi
    call lc_item_int
    ERR_M1 .lp_fail
    mov [rbp - LP_ID], rax
    mov [rbp - LP_FILT + LzFilter.id], rax

    mov rdi, [rbp - LP_TUP]
    lea rsi, [rbp - LP_OPTS]
    mov rdx, rax
    call lc_fill_options
    ERR_NULL .lp_fail
    mov [rbp - LP_FILT + LzFilter.options], rax

    lea rdi, [rbp - LP_SIZE]
    lea rsi, [rbp - LP_FILT]
    call lzma_properties_size wrt ..plt
    test eax, eax
    jnz .lp_failed
    mov eax, [rbp - LP_SIZE]
    cmp eax, 64
    ja .lp_toobig

    lea rdi, [rbp - LP_FILT]
    lea rsi, [rbp - LP_BUF]
    call lzma_properties_encode wrt ..plt
    test eax, eax
    jnz .lp_failed

    lea rdi, [rbp - LP_BUF]
    mov esi, [rbp - LP_SIZE]
    call bytes_from_data
    test rax, rax
    jz .lp_mem
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret

.lp_failed:
    mov edi, eax
    call lc_set_lz
    jmp .lp_fail
.lp_toobig:
    FAIL exc_ValueError_type, "Invalid or unsupported options", .lp_fail
.lp_mem:
    FAIL exc_ValueError_type, "Out of memory", .lp_fail
.lp_type:
    FAIL exc_TypeError_type, "Filter specifier must be a sequence", .lp_fail
.lp_nargs:
    SET_EXC exc_TypeError_type, "_lzmacore: wrong number of arguments"
.lp_fail:
    xor eax, eax
    leave
    ret
END_FUNC lc_encode_filter_props

;; ============================================================================
;; _lzmacore.decode_filter_props(filter_id, props)
;;   -> (lc, lp, pb, dict_size, dist, start_offset), each -1 when the filter
;;      does not carry it
;;
;; The inverse.  lib/_lzma.py turns the tuple into the dict CPython answers,
;; which names only the fields that filter really has -- lc/lp/pb/dict_size
;; for LZMA1, dict_size for LZMA2, dist for delta, start_offset for a BCJ
;; filter that was given one.
;;
;; liblzma ALLOCATES the options here, with plain malloc because the allocator
;; argument is NULL, so they are released with libc's free and not with the
;; pool allocator's.
;; ============================================================================
LQ_ID    equ 8
LQ_PROPS equ 16
LQ_LEN   equ 24
LQ_TUP   equ 32
LQ_FILT  equ 56                     ; an LzFilter, 16 bytes
LQ_FRAME equ 64                     ; + 1 push = 72... padded to 72 below
DEF_FUNC lc_decode_filter_props, 72
    push rbx
    cmp rsi, 2
    jne .lq_nargs
    mov rbx, rdi
    xor esi, esi
    call lc_arg_int
    ERR_M1 .lq_fail
    mov [rbp - LQ_ID], rax
    mov [rbp - LQ_FILT + LzFilter.id], rax
    mov qword [rbp - LQ_FILT + LzFilter.options], 0

    mov rdi, [rbx + 8]
    call lc_buffer
    ERR_PENDING .lq_fail        ; a memoryview that is not contiguous
    test rax, rax
    jnz .lq_have_buf
    jmp .lq_type                ; an empty bytes is a pointer, so 0 is a type
                                ; error however it got here
.lq_have_buf:
    mov [rbp - LQ_PROPS], rax
    mov [rbp - LQ_LEN], rdx

    lea rdi, [rbp - LQ_FILT]
    xor esi, esi                    ; the default allocator: plain malloc
    mov rdx, [rbp - LQ_PROPS]
    mov rcx, [rbp - LQ_LEN]
    call lzma_properties_decode wrt ..plt
    test eax, eax
    jnz .lq_failed

    mov edi, 6
    call tuple_new
    test rax, rax
    jz .lq_mem
    mov [rbp - LQ_TUP], rax

    ; Every slot starts at -1 and the filter's own fields overwrite it.
    mov rdx, [rax + PyTupleObject.ob_item]
    mov ecx, 6
.lq_fill:
    push rdx
    push rcx
    sub rsp, 8
    mov rdi, -1
    call int_from_i64
    V_PACK rax, rdx
    add rsp, 8
    pop rcx
    pop rdx
    mov [rdx], rax
    add rdx, 8
    dec rcx
    jnz .lq_fill

    mov rax, [rbp - LQ_FILT + LzFilter.options]
    test rax, rax
    jz .lq_ready
    mov rcx, [rbp - LQ_ID]
    mov rdx, 0x4000000000000001      ; LZMA_FILTER_LZMA1
    cmp rcx, rdx
    je .lq_lzma1
    cmp rcx, 0x21                    ; LZMA_FILTER_LZMA2
    je .lq_lzma2
    cmp rcx, 3                       ; LZMA_FILTER_DELTA
    je .lq_delta
    ; A BCJ filter: start_offset, in the last slot.
    mov edi, [rax + LC_BCJ_START]
    mov esi, 5
    call lq_set
    jmp .lq_ready
.lq_delta:
    mov edi, [rax + LC_DELTA_DIST]
    mov esi, 4
    call lq_set
    jmp .lq_ready
.lq_lzma1:
    mov edi, [rax + LzOptions.lc]
    xor esi, esi
    call lq_set
    mov rax, [rbp - LQ_FILT + LzFilter.options]
    mov edi, [rax + LzOptions.lp]
    mov esi, 1
    call lq_set
    mov rax, [rbp - LQ_FILT + LzFilter.options]
    mov edi, [rax + LzOptions.pb]
    mov esi, 2
    call lq_set
    mov rax, [rbp - LQ_FILT + LzFilter.options]
.lq_lzma2:
    mov edi, [rax + LzOptions.dict_size]
    mov esi, 3
    call lq_set

.lq_ready:
    mov rdi, [rbp - LQ_FILT + LzFilter.options]
    test rdi, rdi
    jz .lq_done
    call free wrt ..plt
.lq_done:
    mov rax, [rbp - LQ_TUP]
    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.lq_failed:
    mov edi, eax
    call lc_set_lz
    jmp .lq_fail
.lq_mem:
    ; liblzma's options exist by now and are this call's to give back.
    mov rdi, [rbp - LQ_FILT + LzFilter.options]
    test rdi, rdi
    jz .lq_mem_raise
    call free wrt ..plt
.lq_mem_raise:
    FAIL exc_ValueError_type, "Out of memory", .lq_fail
.lq_type:
    FAIL exc_TypeError_type, "the properties must be bytes", .lq_fail
.lq_nargs:
    SET_EXC exc_TypeError_type, "_lzmacore: wrong number of arguments"
.lq_fail:
    xor eax, eax
    pop rbx
    leave
    ret

;; One slot of the answer, written from the caller's frame.  A local label
;; rather than a function, for the reason lc_release_buffers is one.
lq_set:
    push rsi
    sub rsp, 8
    call int_from_i64
    V_PACK rax, rdx
    add rsp, 8
    pop rsi
    mov rdx, [rbp - LQ_TUP]
    mov rdx, [rdx + PyTupleObject.ob_item]
    mov rcx, [rdx + rsi*8]
    mov [rdx + rsi*8], rax
    push rax
    sub rsp, 8
    mov rdi, rcx
    DECREF_V rdi, rax
    add rsp, 8
    pop rax
    ret
END_FUNC lc_decode_filter_props

;; ============================================================================
;; lzma_module_create() -> rax = the module object
;; ============================================================================
LMC_FRAME equ 32            ; + 2 pushes = 48, 16-aligned
DEF_FUNC lzma_module_create, LMC_FRAME
    push rbx
    push r12
    call dict_new
    mov r12, rax                ; MODULE_ADD_FUNC reads the dict from r12

    MODULE_ADD_FUNC lc_encoder,      lc_n_encoder
    MODULE_ADD_FUNC lc_decoder,      lc_n_decoder
    MODULE_ADD_FUNC lc_stream_feed,  lc_n_stream_feed
    MODULE_ADD_FUNC lc_stream_state, lc_n_stream_state
    MODULE_ADD_FUNC lc_stream_free,  lc_n_stream_free
    MODULE_ADD_FUNC lc_check_is_supported, lc_n_check
    MODULE_ADD_FUNC lc_encode_filter_props, lc_n_encode_props
    MODULE_ADD_FUNC lc_decode_filter_props, lc_n_decode_props

    lea rdi, [rel lc_name]
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
END_FUNC lzma_module_create

section .rodata
; The byte offset of each LZMA option the tuple can override, in the tuple's
; own order: dict_size, lc, lp, pb, mode, nice_len, mf, depth.
lc_lzma_offset_bytes: db 0, 20, 24, 28, 32, 36, 40, 44

lc_name:            db "_lzmacore", 0
lc_n_encoder:       db "encoder", 0
lc_n_decoder:       db "decoder", 0
lc_n_stream_feed:   db "stream_feed", 0
lc_n_stream_state:  db "stream_state", 0
lc_n_stream_free:   db "stream_free", 0
lc_n_check:         db "check_is_supported", 0
lc_n_encode_props:  db "encode_filter_props", 0
lc_n_decode_props:  db "decode_filter_props", 0
lc_e_notbytes:      db `a bytes-like object is required, not '\x01'`, 0
