; uniname.asm - resolve a Unicode character name for \N{...}
;
; The table lives in unicodename.asm, which is generated; this is the search
; over it.  Two shapes answer:
;
;   CJK UNIFIED IDEOGRAPH-XXXX   the codepoint is written in the name, so it is
;                                parsed rather than stored -- 97046 entries the
;                                table does not have to carry.  The ranges it
;                                is valid over do come from the table, so a
;                                bogus one is still rejected.
;   everything else              a linear scan of the NUL-separated blob.
;
; The scan is the whole index: `\N{...}` occurs a handful of times in a file at
; most, so a pass over a megabyte costs less -- in code and in generated source
; -- than an offset array and a binary search would.
;
; Matching is case-insensitive, as CPython's is: `\N{latin small letter a}`
; resolves.  Nothing else is normalised; underscores and stray spaces do not.

%include "macros.inc"
%include "object.inc"
%include "compiler.inc"

extern uniname_blob
extern uniname_blob_end
extern uniname_cjk_ranges
extern uniname_cjk_ranges_end
extern ap_memcmp
extern ap_memcpy
extern ap_malloc

section .rodata
uniname_cjk_prefix: db "CJK UNIFIED IDEOGRAPH-", 0
UNINAME_CJK_PREFIX_LEN equ 22

;; ----------------------------------------------------------------------------
;; The checkpoint index uniname_name binary-searches.
;;
;; The blob is FRONT-CODED -- each entry gives a shared prefix length and a
;; suffix, so entry N cannot be decoded without entry N-1 -- which is why a
;; scan for a codepoint started at byte zero every time and cost 13.9 us a
;; call, 280x CPython's.  CPython's test_name_inverse_lookup asks for the name
;; of all 1,114,112 code points, and the module timed out.
;;
;; So every UNIDX_STRIDE entries, record what a scan would need to RESUME
;; there: the blob offset, the running codepoint, and the previous entry's
;; decoded name, which is the prefix state.  A lookup then binary-searches the
;; checkpoints and decodes at most UNIDX_STRIDE entries.  Nothing is
;; precomputed into the binary: the index is built once, on the first call
;; that needs it, and a failure to allocate it falls back to the full scan.
;; ----------------------------------------------------------------------------
UN_BUFSZ_D   equ 128    ; UN_BUFSZ, which is defined below this struc
UNIDX_STRIDE equ 256

struc UnIdx
    .cp:   resq 1       ; the running codepoint at the checkpoint
    .off:  resq 1       ; the blob offset of the next entry to decode
    .name: resb UN_BUFSZ_D
endstruc

section .bss
align 64
unn_index_mutex: resb 64    ; pthread_mutex_t guarding lazy index build
unn_index:   resq 1     ; UnIdx*, or 0
unn_index_n: resq 1
unn_index_tried: resq 1 ; so a failed build is not retried on every call

section .text

;; ============================================================================
;; uniname_lookup(const char *name, int64_t len) -> rax = codepoint, or -1
;; ============================================================================
UN_BUFSZ equ 128         ; must match UNINAME_MAX in gen_unicodename.py
UN_NAME  equ 8
UN_LEN   equ 16
UN_BUF   equ 16 + UN_BUFSZ       ; the name being decoded, NUL-terminated
UN_QBUF  equ UN_BUF + UN_BUFSZ   ; the query, uppercased ONCE
UN_FRAME equ 280         ; UN_QBUF rounded up; + 3 pushes = 304, 16-aligned
DEF_FUNC uniname_lookup, UN_FRAME
    push rbx
    push r12
    push r13
    mov [rbp - UN_NAME], rdi
    mov [rbp - UN_LEN], rsi
    test rsi, rsi
    jle .miss

    ; --- the algorithmic family ---
    cmp rsi, UNINAME_CJK_PREFIX_LEN + 1
    jl .scan_table
    xor ecx, ecx
.cjk_prefix:
    cmp rcx, UNINAME_CJK_PREFIX_LEN
    jae .cjk_have_prefix
    movzx eax, byte [rdi + rcx]
    call .upper
    lea rdx, [rel uniname_cjk_prefix]
    movzx edx, byte [rdx + rcx]
    cmp al, dl
    jne .scan_table
    inc rcx
    jmp .cjk_prefix
.cjk_have_prefix:
    ; The rest must be hex digits, and there must be at least one.
    xor r8, r8                          ; the codepoint
    mov rcx, UNINAME_CJK_PREFIX_LEN
.cjk_hex:
    cmp rcx, [rbp - UN_LEN]
    jae .cjk_hex_done
    movzx eax, byte [rdi + rcx]
    call .upper
    sub eax, '0'
    cmp eax, 9
    jbe .cjk_digit
    sub eax, 'A' - '0'
    cmp eax, 5
    ja .miss
    add eax, 10
.cjk_digit:
    shl r8, 4
    or r8, rax
    cmp r8, 0x10ffff
    ja .miss
    inc rcx
    jmp .cjk_hex
.cjk_hex_done:
    ; ...and inside one of the ranges the name is defined over.
    lea rcx, [rel uniname_cjk_ranges]
    lea rdx, [rel uniname_cjk_ranges_end]
.cjk_range:
    cmp rcx, rdx
    jae .miss
    mov eax, [rcx]
    cmp r8, rax
    jb .cjk_range_next
    mov eax, [rcx + 4]
    cmp r8, rax
    jbe .cjk_hit
.cjk_range_next:
    add rcx, 8
    jmp .cjk_range
.cjk_hit:
    mov rax, r8
    jmp .done

    ; --- the table ---
    ;
    ; Entries are front-coded against their predecessor, so the scan decodes
    ; as it walks: `shared` bytes of the previous name stay in the buffer and
    ; only the suffix is copied in.  The scan was already strictly sequential,
    ; which is the whole reason the encoding is free here.
    ;
    ; The codepoint rides the same stream as a delta, with 255 escaping to an
    ; absolute for the thirty-one places the sequence jumps -- chiefly the
    ; aliases at the end, which are not in codepoint order at all.
.scan_table:
    ; Uppercase the query ONCE.  It used to be folded a character at a time,
    ; through a call, for every entry -- 46,100 times over a failing lookup.
    mov rsi, [rbp - UN_LEN]
    cmp rsi, UN_BUFSZ
    jae .miss                           ; longer than the buffer can hold with
                                        ; its NUL, and so longer than any name
                                        ; the generator will emit.  UN_BUFSZ-1
                                        ; here rejected a name of exactly
                                        ; UNINAME_MAX-1 bytes, which fits
    mov rdi, [rbp - UN_NAME]
    lea rdx, [rbp - UN_QBUF]
    xor ecx, ecx
.upcase:
    cmp rcx, rsi
    jae .upcased
    mov al, [rdi + rcx]
    cmp al, 'a'
    jb .up_store
    cmp al, 'z'
    ja .up_store
    sub al, 32
.up_store:
    mov [rdx + rcx], al
    inc rcx
    jmp .upcase
.upcased:

    lea rbx, [rel uniname_blob]
    lea r13, [rel uniname_blob_end]
    xor r12, r12                        ; the running codepoint
.entry:
    cmp rbx, r13
    jae .miss
    movzx ecx, byte [rbx]               ; bytes shared with the previous name
    movzx eax, byte [rbx + 1]           ; codepoint delta, or 255
    add rbx, 2
    cmp eax, 255
    jne .cp_delta
    mov eax, [rbx]                      ; the absolute that follows the escape
    add rbx, 4
    mov r12d, eax
    jmp .cp_done
.cp_delta:
    add r12, rax
.cp_done:

    ; Copy this entry's suffix in after the prefix already in the buffer.
    lea rdx, [rbp - UN_BUF]
    add rdx, rcx
.copy:
    mov al, [rbx]
    inc rbx
    mov [rdx], al
    inc rdx
    test al, al
    jnz .copy

    ; The buffer now holds the whole name.  Its length rejects almost every
    ; entry without looking at a byte of it.
    lea rax, [rbp - UN_BUF]
    sub rdx, rax
    dec rdx                             ; rdx = the decoded name's length
    cmp rdx, [rbp - UN_LEN]
    jne .entry
    lea rdi, [rbp - UN_BUF]
    lea rsi, [rbp - UN_QBUF]
    call ap_memcmp                      ; rdx is already the length
    test eax, eax
    jnz .entry
    mov rax, r12
    jmp .done

.miss:
    mov rax, -1
.done:
    pop r13
    pop r12
    pop rbx
    leave
    ret

; Local: uppercase the ASCII letter in al, leaving everything else alone.
.upper:
    cmp al, 'a'
    jb .upper_done
    cmp al, 'z'
    ja .upper_done
    sub al, 32
.upper_done:
    ret
END_FUNC uniname_lookup

;; ============================================================================
;; unn_build_index() -> rax = 1 when the index is there, 0 when it is not
;;
;; One walk of the blob, recording a checkpoint every UNIDX_STRIDE entries.
;; Called once, from the first uniname_name that needs it; a failure to
;; allocate is remembered so it is not retried on every call, and the scan
;; then runs from byte zero as it always did.
;; ============================================================================
UBI_ARR   equ 8
UBI_CAP   equ 16
UBI_N     equ 24
UBI_CNT   equ 32
UBI_BUF   equ 32 + UN_BUFSZ_D   ; the decode buffer, below the scalars
UBI_FRAME equ 32 + UN_BUFSZ_D   ; + 4 pushes = 192, 16-aligned
DEF_FUNC_LOCAL unn_build_index, UBI_FRAME
    push rbx
    push r12
    push r13
    push r14
    mov rax, [rel unn_index]
    test rax, rax
    jnz .ubi_have
    extern pthread_mutex_lock
    extern pthread_mutex_unlock
    lea rdi, [rel unn_index_mutex]
    call pthread_mutex_lock wrt ..plt
    mov rax, [rel unn_index]
    test rax, rax
    jnz .ubi_have_unlock
    cmp qword [rel unn_index_tried], 0
    jne .ubi_none_unlock
    mov qword [rel unn_index_tried], 1

    ; cap = blob_size / (3 * stride) + 2.  Three bytes is the shortest an
    ; entry can be -- a shared length, a delta, and the suffix's NUL.
    lea rax, [rel uniname_blob_end]
    lea rcx, [rel uniname_blob]
    sub rax, rcx
    xor edx, edx
    mov rcx, 3 * UNIDX_STRIDE
    div rcx
    add rax, 2
    mov [rbp - UBI_CAP], rax
    mov rdi, UnIdx_size
    imul rdi, rax
    call ap_malloc
    test rax, rax
    jz .ubi_none_unlock
    mov [rbp - UBI_ARR], rax

    lea rbx, [rel uniname_blob]
    lea r13, [rel uniname_blob_end]
    xor r12d, r12d                      ; the running codepoint
    mov r14, -1                         ; the previous one
    mov qword [rbp - UBI_N], 0
    mov qword [rbp - UBI_CNT], 0
.ubi_entry:
    cmp rbx, r13
    jae .ubi_done
    mov rax, [rbp - UBI_CNT]
    test rax, UNIDX_STRIDE - 1
    jnz .ubi_no_cp
    mov r8, [rbp - UBI_N]
    cmp r8, [rbp - UBI_CAP]
    jae .ubi_no_cp                      ; full, which the sizing rules out
    mov r9, UnIdx_size
    imul r9, r8
    add r9, [rbp - UBI_ARR]
    mov [r9 + UnIdx.cp], r12
    mov [r9 + UnIdx.off], rbx
    lea r10, [rbp - UBI_BUF]
    add r9, UnIdx.name
    xor eax, eax
.ubi_copy_name:
    mov dl, [r10 + rax]
    mov [r9 + rax], dl
    inc eax
    cmp eax, UN_BUFSZ_D
    jb .ubi_copy_name
    inc qword [rbp - UBI_N]
.ubi_no_cp:
    inc qword [rbp - UBI_CNT]

    movzx ecx, byte [rbx]               ; the shared prefix length
    movzx eax, byte [rbx + 1]
    add rbx, 2
    cmp eax, 255
    jne .ubi_delta
    mov eax, [rbx]
    add rbx, 4
    mov r12d, eax
    jmp .ubi_cp_done
.ubi_delta:
    add r12, rax
.ubi_cp_done:
    cmp r12, r14
    jl .ubi_done                        ; the aliases start here
    mov r14, r12
    lea rdx, [rbp - UBI_BUF]
    add rdx, rcx
.ubi_copy:
    mov al, [rbx]
    inc rbx
    mov [rdx], al
    inc rdx
    test al, al
    jnz .ubi_copy
    jmp .ubi_entry

.ubi_done:
    ; Publish count before pointer so lock-free readers observing unn_index != 0
    ; always see a valid unn_index_n (x86-TSO release order).
    mov rax, [rbp - UBI_N]
    mov [rel unn_index_n], rax
    mov rax, [rbp - UBI_ARR]
    mov [rel unn_index], rax
.ubi_have_unlock:
    lea rdi, [rel unn_index_mutex]
    call pthread_mutex_unlock wrt ..plt
.ubi_have:
    mov eax, 1
    jmp .ubi_out
.ubi_none_unlock:
    lea rdi, [rel unn_index_mutex]
    call pthread_mutex_unlock wrt ..plt
.ubi_none:
    xor eax, eax
.ubi_out:
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC unn_build_index

;; ============================================================================
;; unn_seek(rdi = target codepoint, rsi = out buffer)
;;   -> rax = the blob pointer to resume at, rdx = the running codepoint
;;
;; Binary-searches the checkpoints for the last one at or below the target and
;; restores the prefix state into the caller's buffer.  With no index it
;; answers the start of the blob, which is what the scan used to do always.
;; ============================================================================
USK_CP    equ 8
USK_OUT   equ 16
USK_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
DEF_FUNC_LOCAL unn_seek, USK_FRAME
    mov [rbp - USK_CP], rdi
    mov [rbp - USK_OUT], rsi
    call unn_build_index
    test eax, eax
    jz .usk_start
    mov r8, [rel unn_index]
    mov r9, [rel unn_index_n]
    test r9, r9
    jz .usk_start

    ; lo = 0, hi = n - 1; the answer is the last cp <= target, and entry 0 is
    ; the start of the blob, so there is always one.
    xor esi, esi                        ; lo
    mov rdi, r9
    dec rdi                             ; hi
    xor r10d, r10d                      ; the best index so far
.usk_search:
    cmp rsi, rdi
    ja .usk_found
    mov rax, rsi
    add rax, rdi
    shr rax, 1                          ; mid
    mov rcx, UnIdx_size
    imul rcx, rax
    add rcx, r8
    mov rdx, [rcx + UnIdx.cp]
    ; STRICTLY below the target.  A checkpoint records the state BEFORE its
    ; entry is decoded, so its codepoint is the PREVIOUS entry's -- and
    ; resuming at a checkpoint whose codepoint IS the target steps straight
    ; past the entry that answers it.  Four characters lost their name that
    ; way, which is what a sampled round trip catches and a spot check does
    ; not.
    cmp rdx, [rbp - USK_CP]
    jae .usk_high
    mov r10, rax
    lea rsi, [rax + 1]
    jmp .usk_search
.usk_high:
    test rax, rax
    jz .usk_found
    lea rdi, [rax - 1]
    jmp .usk_search

.usk_found:
    mov rcx, UnIdx_size
    imul rcx, r10
    add rcx, r8
    mov rdx, [rcx + UnIdx.cp]
    mov rax, [rcx + UnIdx.off]
    add rcx, UnIdx.name
    mov rdi, [rbp - USK_OUT]
    xor r11d, r11d
.usk_restore:
    mov r9b, [rcx + r11]
    mov [rdi + r11], r9b
    inc r11d
    cmp r11d, UN_BUFSZ_D
    jb .usk_restore
    leave
    ret

.usk_start:
    lea rax, [rel uniname_blob]
    xor edx, edx
    leave
    ret
END_FUNC unn_seek

;; ============================================================================
;; uniname_name(rdi = codepoint, rsi = out buffer, rdx = its size)
;;   -> rax = the name's length, or -1 when the character has none
;;
;; The same blob and the same decoder as uniname_lookup, walked for a
;; CODEPOINT instead of a name.  The buffer must be at least UN_BUFSZ bytes:
;; the decoder needs the previous entry's prefix in it whether or not that
;; entry is the answer.
;;
;; Two things stop the scan early, and the second is not an optimisation.  The
;; blob is in codepoint order, so a running codepoint past the target means
;; the target has no entry.  And the ALIASES are appended after it, out of
;; order -- a codepoint that DECREASES is where they start.  They must not be
;; reached: `unicodedata.lookup('LF')` is U+000A in CPython and
;; `unicodedata.name('\n')` is a ValueError, because an alias is a way in and
;; not the character's name.
;;
;; CJK UNIFIED IDEOGRAPH-XXXX is synthesised, as it is parsed on the way in.
;; ============================================================================
UNN_CP    equ 8
UNN_OUT   equ 16
UNN_SIZE  equ 24
UNN_FRAME equ 40            ; + 3 pushes = 64, 16-aligned
DEF_FUNC uniname_name, UNN_FRAME
    push rbx
    push r12
    push r13
    mov [rbp - UNN_CP], rdi
    mov [rbp - UNN_OUT], rsi
    mov [rbp - UNN_SIZE], rdx
    cmp rdx, UN_BUFSZ
    jl .unn_miss

    ; The algorithmic family first: its names are not in the blob.
    lea rcx, [rel uniname_cjk_ranges]
    lea rdx, [rel uniname_cjk_ranges_end]
.unn_cjk_range:
    cmp rcx, rdx
    jae .unn_scan
    mov eax, [rcx]
    cmp rdi, rax
    jb .unn_cjk_next
    mov eax, [rcx + 4]
    cmp rdi, rax
    jbe .unn_cjk_hit
.unn_cjk_next:
    add rcx, 8
    jmp .unn_cjk_range

.unn_cjk_hit:
    ; "CJK UNIFIED IDEOGRAPH-" and the codepoint in uppercase hex, with at
    ; least four digits, which is how the UCD writes it.
    mov rdi, [rbp - UNN_OUT]
    lea rsi, [rel uniname_cjk_prefix]
    xor ecx, ecx
.unn_cjk_copy:
    cmp rcx, UNINAME_CJK_PREFIX_LEN
    jae .unn_cjk_hex
    mov al, [rsi + rcx]
    mov [rdi + rcx], al
    inc rcx
    jmp .unn_cjk_copy
.unn_cjk_hex:
    ; How many digits: four, or more when the codepoint needs them.
    mov r8, [rbp - UNN_CP]
    mov r9d, 4
    mov rax, r8
    shr rax, 16
    test rax, rax
    jz .unn_cjk_digits
    mov r9d, 5
    mov rax, r8
    shr rax, 20
    test rax, rax
    jz .unn_cjk_digits
    mov r9d, 6
.unn_cjk_digits:
    lea r10, [rcx + r9]                 ; the total length
    mov r11, r9
.unn_cjk_digit:
    dec r11
    js .unn_cjk_done
    mov rax, r8
    mov edx, r11d
    shl edx, 2
    mov ecx, edx
    shr rax, cl
    and eax, 15
    cmp eax, 9
    jbe .unn_cjk_num
    add eax, 'A' - 10
    jmp .unn_cjk_put
.unn_cjk_num:
    add eax, '0'
.unn_cjk_put:
    ; r11 counts DOWN from the most significant digit, and the most
    ; significant one goes FIRST: position is (digits - 1 - r11), not r11.
    ; Writing it the other way spelled U+4E00 as 00E4.
    lea rcx, [r9 - 1]
    sub rcx, r11
    add rcx, UNINAME_CJK_PREFIX_LEN
    mov [rdi + rcx], al
    jmp .unn_cjk_digit
.unn_cjk_done:
    mov byte [rdi + r10], 0
    mov rax, r10
    jmp .unn_done

.unn_scan:
    ; Start from the last checkpoint at or below the target rather than from
    ; byte zero; see the block above unn_build_index.
    mov rdi, [rbp - UNN_CP]
    mov rsi, [rbp - UNN_OUT]
    call unn_seek
    mov rbx, rax
    mov r12, rdx                        ; the running codepoint
    mov r9, rdx                         ; the previous one
    lea r13, [rel uniname_blob_end]
    test rdx, rdx
    jnz .unn_entry
    mov r9, -1                          ; from the start, nothing is previous
.unn_entry:
    cmp rbx, r13
    jae .unn_miss
    movzx ecx, byte [rbx]
    movzx eax, byte [rbx + 1]
    add rbx, 2
    cmp eax, 255
    jne .unn_delta
    mov eax, [rbx]
    add rbx, 4
    mov r12d, eax
    jmp .unn_cp_done
.unn_delta:
    add r12, rax
.unn_cp_done:
    ; Out of the ordered region: what follows is the aliases.
    cmp r12, r9
    jl .unn_miss
    mov r9, r12

    ; The suffix goes in after the prefix already there, whether or not this
    ; entry is the one: the next entry's prefix is this entry's.
    mov rdx, [rbp - UNN_OUT]
    add rdx, rcx
.unn_copy:
    mov al, [rbx]
    inc rbx
    mov [rdx], al
    inc rdx
    test al, al
    jnz .unn_copy

    cmp r12, [rbp - UNN_CP]
    je .unn_hit
    jg .unn_miss
    jmp .unn_entry

.unn_hit:
    mov rax, [rbp - UNN_OUT]
    sub rdx, rax                        ; the NUL is counted
    lea rax, [rdx - 1]
    jmp .unn_done

.unn_miss:
    mov rax, -1
.unn_done:
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC uniname_name

ASM_INIT
