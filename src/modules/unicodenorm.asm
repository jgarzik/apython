; modules/unicodenorm.asm - the four normal forms, over the generated tables
;
; `unicodedata.normalize` and `unicodedata.decomposition`, which were the two
; functions the module did not have: they need the decomposition mappings, the
; canonical combining classes and the pairs that recompose, which is an order
; of magnitude more data than the seven properties in unicodedataprops.asm.
; src/compiler/gen_unicodenorm.py emits it; `make regen` rewrites it.
;
; The algorithm is UAX #15 and is the same four steps whichever form is asked
; for:
;
;   1. decompose -- fully, because the table is already fully expanded, so
;      each character is looked up once and nothing recurses.  A canonical
;      decomposition for NFD and NFC; a compatibility one, which subsumes it,
;      for NFKD and NFKC.
;   2. reorder -- a stable insertion sort over each run of non-starters, by
;      canonical combining class.  Stability is not an optimisation here: it
;      is what the standard specifies, and an unstable sort gives a different
;      (and wrong) answer for three or more marks of equal class.
;   3. compose, for NFC and NFKC only -- walk left to right holding the last
;      starter, and fold each following character into it when the pair is in
;      the table and nothing of an equal-or-higher class stands between them.
;   4. encode.
;
; Hangul is in neither table: both directions are arithmetic, and doing it
; that way is what keeps 11,172 syllables and their 3 x 19 x 21 x 28 jamo out
; of the generated file.
;
; The intermediate is an array of CODE POINTS rather than UTF-8, because step
; 2 reorders and step 3 deletes, and doing either in a variable-width encoding
; means moving bytes for every swap.  UdnBuf below is that array; it grows by
; doubling and is freed on every exit, including the raising ones.
;
; A Python reference for all of this, checked against CPython's own
; normalize() over every code point and 200,000 random sequences, is what the
; tables were verified with before any of this was written.

%include "macros.inc"
%include "object.inc"
%include "value.inc"

section .text

extern ap_malloc
extern ap_free
extern ap_realloc
extern ap_memcpy
extern str_new_heap
extern bool_true
extern bool_false
extern str_type
extern obj_incref
extern obj_decref
extern exc_TypeError_type
extern exc_ValueError_type
extern set_exception

extern udn_index
extern udn_index_count
extern udn_pool
extern udn_pairs
extern udn_pair_count
extern udn_ccc
extern udn_ccc_count
extern udn_tags
extern udn_raw_index
extern udn_raw_count
extern udn_raw_pool

; Which DATABASE the lookups read.  There are two: the current one, and the
; frozen Unicode 3.2 copy `stringprep` is written against (ucd_3_2_0).  They
; have identical table shapes and differ only in their contents, so one engine
; serves both and the only thing that varies is where it reads.
;
; The pointer is a file-scoped word rather than an argument threaded through
; eight functions, and what makes that safe is that NOTHING here runs Python:
; the input is a str's own bytes, the tables are integers, and the only calls
; out are to the allocator and to str_new_heap.  So normalize() cannot re-enter
; itself, and a signal handler runs at the top of the eval loop rather than
; inside a builtin.  Each entry point sets it before the first lookup.
struc UdnTables
    .index:       resq 1
    .index_count: resq 1
    .pool:        resq 1
    .pairs:       resq 1
    .pair_count:  resq 1
    .ccc:         resq 1
    .ccc_count:   resq 1
    .raw_index:   resq 1
    .raw_count:   resq 1
    .raw_pool:    resq 1
    .tags:        resq 1
endstruc

; One row of udn_index: the code point, then the canonical span and the
; compatibility span into udn_pool.  Five dwords, so the stride is 20 and a
; binary search multiplies rather than shifts.
UDN_ROW      equ 20
UDN_ROW_CP   equ 0
UDN_ROW_CO   equ 4
UDN_ROW_CL   equ 8
UDN_ROW_KO   equ 12
UDN_ROW_KL   equ 16

; Hangul, from UAX #15's own names.
SBASE  equ 0xAC00
LBASE  equ 0x1100
VBASE  equ 0x1161
TBASE  equ 0x11A7
LCOUNT equ 19
VCOUNT equ 21
TCOUNT equ 28
NCOUNT equ VCOUNT * TCOUNT          ; 588
SCOUNT equ LCOUNT * NCOUNT          ; 11172

; The growable code-point array the three steps share.
struc UdnBuf
    .data: resq 1                   ; uint32_t *, or 0
    .len:  resq 1
    .cap:  resq 1
endstruc

;; ============================================================================
;; udn_ccc_of(rdi = a code point) -> rax = its canonical combining class
;;
;; Zero for all but 922 code points, so only those are in the table and a miss
;; is the answer rather than an error.
;; ============================================================================
global udn_ccc_of
DEF_FUNC_BARE udn_ccc_of
    mov r11, [rel udn_active]
    mov r8, [r11 + UdnTables.ccc]
    mov r9, [r11 + UdnTables.ccc_count]
    xor rcx, rcx                    ; lo
.loop:
    cmp rcx, r9
    jae .zero
    mov rax, r9
    sub rax, rcx
    shr rax, 1
    add rax, rcx                    ; mid
    mov edx, [r8 + rax*8]
    cmp edx, edi
    je .found
    jb .go_right
    mov r9, rax
    jmp .loop
.go_right:
    lea rcx, [rax + 1]
    jmp .loop
.found:
    mov eax, [r8 + rax*8 + 4]
    ret
.zero:
    xor eax, eax
    ret
END_FUNC udn_ccc_of

;; ============================================================================
;; udn_row_for(rdi = a code point) -> rax = the udn_index row, or 0
;; ============================================================================
global udn_row_for
DEF_FUNC_BARE udn_row_for
    mov r11, [rel udn_active]
    mov r8, [r11 + UdnTables.index]
    mov r9, [r11 + UdnTables.index_count]
    xor rcx, rcx
.loop:
    cmp rcx, r9
    jae .none
    mov rax, r9
    sub rax, rcx
    shr rax, 1
    add rax, rcx
    mov r10, rax
    imul r10, r10, UDN_ROW
    add r10, r8
    mov edx, [r10 + UDN_ROW_CP]
    cmp edx, edi
    je .found
    jb .go_right
    mov r9, rax
    jmp .loop
.go_right:
    lea rcx, [rax + 1]
    jmp .loop
.found:
    mov rax, r10
    ret
.none:
    xor eax, eax
    ret
END_FUNC udn_row_for

;; ============================================================================
;; udn_compose_pair(rdi = the starter, rsi = the character after it)
;;   -> rax = the composite, or 0
;;
;; Hangul first, because it is not in the table: an L and a V make an LV
;; syllable, and an LV with no trailing consonant plus a T makes an LVT.
;; Everything else is the generated pair table, keyed by (a << 21) | b so that
;; the search compares one number.
;; ============================================================================
global udn_compose_pair
DEF_FUNC_BARE udn_compose_pair
    ; L + V
    mov eax, edi
    sub eax, LBASE
    cmp eax, LCOUNT
    jae .not_lv
    mov edx, esi
    sub edx, VBASE
    cmp edx, VCOUNT
    jae .not_lv
    imul eax, eax, VCOUNT
    add eax, edx
    imul eax, eax, TCOUNT
    add eax, SBASE
    ret
.not_lv:
    ; LV + T, only when the syllable has no trailing consonant yet
    mov eax, edi
    sub eax, SBASE
    cmp eax, SCOUNT
    jae .table
    xor edx, edx
    mov r8d, TCOUNT
    div r8d                         ; edx = (cp - SBASE) % TCOUNT
    test edx, edx
    jnz .table
    mov eax, esi
    sub eax, TBASE
    cmp eax, TCOUNT
    jae .table
    test eax, eax
    jz .table                       ; TBASE itself is not a filler
    add eax, edi
    ret

.table:
    mov r10, rdi
    shl r10, 21
    or r10, rsi                     ; the packed key
    mov r11, [rel udn_active]
    mov r8, [r11 + UdnTables.pairs]
    mov r9, [r11 + UdnTables.pair_count]
    xor rcx, rcx
.loop:
    cmp rcx, r9
    jae .none
    mov rax, r9
    sub rax, rcx
    shr rax, 1
    add rax, rcx
    lea rdx, [rax + rax]        ; x86 scales by 1, 2, 4 or 8; a 16-byte row
    mov rdx, [r8 + rdx*8]       ; is two of the largest
    cmp rdx, r10
    je .found
    jb .go_right
    mov r9, rax
    jmp .loop
.go_right:
    lea rcx, [rax + 1]
    jmp .loop
.found:
    lea rdx, [rax + rax]
    mov rax, [r8 + rdx*8 + 8]
    ret
.none:
    xor eax, eax
    ret
END_FUNC udn_compose_pair

;; ============================================================================
;; udn_buf_push(rdi = UdnBuf*, rsi = a code point) -> rax = 1, or 0 with a
;;   MemoryError pending
;;
;; Doubling, from a first block of 64: the common input is short and the
;; expansion factor of a decomposition is small, so a fixed guess would be
;; wrong in both directions.
;; ============================================================================
UBP_BUF  equ 8
UBP_CP   equ 16
UBP_FRAME equ 32                    ; + 0 pushes = 32, 16-aligned
global udn_buf_push
DEF_FUNC udn_buf_push, UBP_FRAME
    mov [rbp - UBP_BUF], rdi
    mov [rbp - UBP_CP], rsi
    mov rax, [rdi + UdnBuf.len]
    cmp rax, [rdi + UdnBuf.cap]
    jb .store

    mov rcx, [rdi + UdnBuf.cap]
    test rcx, rcx
    jnz .double
    mov ecx, 64
    jmp .resize
.double:
    add rcx, rcx
.resize:
    push rcx
    push rcx                        ; twice: rsp stays 16-byte aligned
    mov rdi, [rdi + UdnBuf.data]
    lea rsi, [rcx*4]
    call ap_realloc                 ; a NULL `old` is a plain malloc
    pop rcx
    pop rcx
    test rax, rax
    jz .oom
    mov rdi, [rbp - UBP_BUF]
    mov [rdi + UdnBuf.data], rax
    mov [rdi + UdnBuf.cap], rcx

.store:
    mov rdi, [rbp - UBP_BUF]
    mov rax, [rdi + UdnBuf.len]
    mov rcx, [rdi + UdnBuf.data]
    mov rdx, [rbp - UBP_CP]
    mov [rcx + rax*4], edx
    inc qword [rdi + UdnBuf.len]
    mov eax, 1
    leave
    ret
.oom:
    extern exc_MemoryError_type
    lea rdi, [rel exc_MemoryError_type]
    CSTRING rsi, "out of memory normalizing"
    call set_exception
    xor eax, eax
    leave
    ret
END_FUNC udn_buf_push

;; ============================================================================
;; udn_decompose_cp(rdi = UdnBuf*, rsi = a code point, rdx = 1 for the
;;                  compatibility mapping) -> rax = 1, or 0 with an exception
;;
;; One character's contribution to step 1.  Hangul is computed; everything
;; else is one table row, whose canonical span is used when the compatibility
;; one is empty -- a character with only a canonical mapping has the same
;; decomposition under both.
;; ============================================================================
UDC_BUF  equ 8
UDC_CP   equ 16
UDC_K    equ 24
UDC_PTR  equ 32
UDC_END  equ 40
UDC_FRAME equ 48                    ; + 0 pushes = 48, 16-aligned
global udn_decompose_cp
DEF_FUNC udn_decompose_cp, UDC_FRAME
    mov [rbp - UDC_BUF], rdi
    mov [rbp - UDC_CP], rsi
    mov [rbp - UDC_K], rdx

    ; Hangul: S = SBASE + (L * VCOUNT + V) * TCOUNT + T
    mov eax, esi
    sub eax, SBASE
    cmp eax, SCOUNT
    jae .table
    xor edx, edx
    mov r8d, NCOUNT
    div r8d                         ; eax = L index, edx = remainder
    mov r9d, edx
    add eax, LBASE
    mov [rbp - UDC_PTR], rax        ; L, across the call
    mov eax, r9d
    xor edx, edx
    mov r8d, TCOUNT
    div r8d                         ; eax = V index, edx = T index
    add eax, VBASE
    mov [rbp - UDC_END], rax        ; V
    mov r10d, edx
    push r10
    push r10                        ; twice: rsp stays 16-byte aligned
    mov rdi, [rbp - UDC_BUF]
    mov rsi, [rbp - UDC_PTR]
    call udn_buf_push
    test eax, eax
    jz .hangul_failed
    mov rdi, [rbp - UDC_BUF]
    mov rsi, [rbp - UDC_END]
    call udn_buf_push
    test eax, eax
    jz .hangul_failed
    pop r10
    pop r10
    test r10d, r10d
    jz .ok
    mov rdi, [rbp - UDC_BUF]
    lea rsi, [r10 + TBASE]
    call udn_buf_push
    leave
    ret
.hangul_failed:
    pop r10
    pop r10
    xor eax, eax
    leave
    ret

.table:
    mov rdi, [rbp - UDC_CP]
    call udn_row_for
    test rax, rax
    jz .as_is
    mov r8, rax
    xor ecx, ecx
    cmp qword [rbp - UDC_K], 0
    je .canonical
    mov ecx, [r8 + UDN_ROW_KL]
    test ecx, ecx
    jz .canonical                   ; no compatibility mapping of its own
    mov edx, [r8 + UDN_ROW_KO]
    jmp .have_span
.canonical:
    mov ecx, [r8 + UDN_ROW_CL]
    test ecx, ecx
    jz .as_is
    mov edx, [r8 + UDN_ROW_CO]
.have_span:
    mov rax, [rel udn_active]
    mov rax, [rax + UdnTables.pool]
    lea rdx, [rax + rdx*4]
    mov [rbp - UDC_PTR], rdx
    lea rcx, [rdx + rcx*4]
    mov [rbp - UDC_END], rcx
.span_loop:
    mov rdx, [rbp - UDC_PTR]
    cmp rdx, [rbp - UDC_END]
    jae .ok
    mov esi, [rdx]
    add qword [rbp - UDC_PTR], 4
    mov rdi, [rbp - UDC_BUF]
    call udn_buf_push
    test eax, eax
    jz .failed
    jmp .span_loop

.as_is:
    mov rdi, [rbp - UDC_BUF]
    mov rsi, [rbp - UDC_CP]
    call udn_buf_push
    leave
    ret
.ok:
    mov eax, 1
    leave
    ret
.failed:
    xor eax, eax
    leave
    ret
END_FUNC udn_decompose_cp

;; ============================================================================
;; udn_reorder(rdi = UdnBuf*) -> nothing
;;
;; Step 2, the canonical ordering algorithm: a STABLE insertion sort by
;; combining class over each run of non-starters.  A starter (class 0) never
;; moves and nothing moves past it, which is what makes the sort local.
;;
;; Stability is the specification, not a choice: three marks of equal class
;; must keep their written order, and an unstable sort changes the string.
;; ============================================================================
UDR_BUF equ 8
UDR_I   equ 16
UDR_J   equ 24
UDR_CC  equ 32
UDR_FRAME equ 40                    ; + 1 push = 48, 16-aligned
global udn_reorder
DEF_FUNC udn_reorder, UDR_FRAME
    push rbx
    mov [rbp - UDR_BUF], rdi
    mov qword [rbp - UDR_I], 1
.outer:
    mov rdi, [rbp - UDR_BUF]
    mov rax, [rbp - UDR_I]
    cmp rax, [rdi + UdnBuf.len]
    jae .done
    mov rbx, [rdi + UdnBuf.data]
    mov edi, [rbx + rax*4]
    call udn_ccc_of
    mov [rbp - UDR_CC], rax
    test rax, rax
    jz .next                        ; a starter never moves
    mov rax, [rbp - UDR_I]
    mov [rbp - UDR_J], rax
.inner:
    mov rax, [rbp - UDR_J]
    cmp rax, 1
    jb .next
    dec rax
    mov edi, [rbx + rax*4]
    call udn_ccc_of
    cmp rax, [rbp - UDR_CC]
    jbe .next                       ; in order, and equal classes do not swap
    mov rax, [rbp - UDR_J]
    mov ecx, [rbx + rax*4]
    mov edx, [rbx + rax*4 - 4]
    mov [rbx + rax*4], edx
    mov [rbx + rax*4 - 4], ecx
    dec qword [rbp - UDR_J]
    jmp .inner
.next:
    inc qword [rbp - UDR_I]
    jmp .outer
.done:
    pop rbx
    leave
    ret
END_FUNC udn_reorder

;; ============================================================================
;; udn_compose(rdi = UdnBuf*) -> nothing
;;
;; Step 3, in place: the array only ever shrinks, so the output index trails
;; the input one and no second buffer is needed.
;;
;; The rule that makes it correct is the BLOCKED test.  A character can fold
;; into the last starter only when nothing between them has a combining class
;; greater than or equal to its own -- otherwise `a` + a class-230 mark + a
;; class-230 mark would compose the second mark into `a` and change what the
;; first one is attached to.
;; ============================================================================
UDK_BUF     equ 8
UDK_OUT     equ 16
UDK_IN      equ 24
UDK_STARTER equ 32                  ; index into the OUTPUT, or -1
UDK_LASTCC  equ 40
UDK_CC      equ 48
UDK_CP      equ 56
UDK_FRAME   equ 56                  ; + 1 push = 64, 16-aligned
global udn_compose
DEF_FUNC udn_compose, UDK_FRAME
    push rbx
    mov [rbp - UDK_BUF], rdi
    mov rbx, [rdi + UdnBuf.data]
    cmp qword [rdi + UdnBuf.len], 0
    je .done

    mov edi, [rbx]
    call udn_ccc_of
    mov [rbp - UDK_LASTCC], rax
    mov qword [rbp - UDK_STARTER], -1
    test rax, rax
    jnz .first_stored
    mov qword [rbp - UDK_STARTER], 0
.first_stored:
    mov qword [rbp - UDK_OUT], 1
    mov qword [rbp - UDK_IN], 1

.loop:
    mov rax, [rbp - UDK_IN]
    mov rcx, [rbp - UDK_BUF]
    cmp rax, [rcx + UdnBuf.len]
    jae .done
    mov edi, [rbx + rax*4]
    mov [rbp - UDK_CP], rdi
    call udn_ccc_of
    mov [rbp - UDK_CC], rax

    cmp qword [rbp - UDK_STARTER], 0
    jl .emit
    ; Not blocked: either the previous character was a starter, or its class
    ; is strictly below this one's.
    mov rax, [rbp - UDK_LASTCC]
    test rax, rax
    jz .try_compose
    cmp rax, [rbp - UDK_CC]
    jae .emit
.try_compose:
    mov rcx, [rbp - UDK_STARTER]
    mov edi, [rbx + rcx*4]
    mov rsi, [rbp - UDK_CP]
    call udn_compose_pair
    test eax, eax
    jz .emit
    mov rcx, [rbp - UDK_STARTER]
    mov [rbx + rcx*4], eax          ; the starter becomes the composite
    inc qword [rbp - UDK_IN]
    jmp .loop                       ; LASTCC is unchanged: nothing was emitted

.emit:
    mov rax, [rbp - UDK_OUT]
    mov rcx, [rbp - UDK_CP]
    mov [rbx + rax*4], ecx
    cmp qword [rbp - UDK_CC], 0
    jne .emit_mark
    mov [rbp - UDK_STARTER], rax    ; a new starter to fold into
.emit_mark:
    mov rax, [rbp - UDK_CC]
    mov [rbp - UDK_LASTCC], rax
    inc qword [rbp - UDK_OUT]
    inc qword [rbp - UDK_IN]
    jmp .loop

.done:
    mov rcx, [rbp - UDK_BUF]
    cmp qword [rcx + UdnBuf.len], 0
    je .empty
    mov rax, [rbp - UDK_OUT]
    mov [rcx + UdnBuf.len], rax
.empty:
    pop rbx
    leave
    ret
END_FUNC udn_compose

;; ============================================================================
;; udn_encode(rdi = UdnBuf*) -> rax = PyStrObject*, or 0 with an exception
;;
;; Step 4.  The byte buffer is sized at four per code point, which is UTF-8's
;; maximum and is what a single pass needs: measuring first would walk the
;; array twice to save at most three quarters of a temporary.
;; ============================================================================
UDE_BUF  equ 8
UDE_BYTES equ 16
UDE_OUT  equ 24
UDE_I    equ 32
UDE_FRAME equ 40                    ; + 1 push = 48, 16-aligned
global udn_encode
DEF_FUNC udn_encode, UDE_FRAME
    push rbx
    mov [rbp - UDE_BUF], rdi
    mov rax, [rdi + UdnBuf.len]
    lea rdi, [rax*4 + 8]
    call ap_malloc
    test rax, rax
    jz .oom
    mov rbx, rax
    mov [rbp - UDE_BYTES], rax
    mov qword [rbp - UDE_OUT], 0
    mov qword [rbp - UDE_I], 0

.loop:
    mov rcx, [rbp - UDE_BUF]
    mov rax, [rbp - UDE_I]
    cmp rax, [rcx + UdnBuf.len]
    jae .finish
    mov rdx, [rcx + UdnBuf.data]
    mov eax, [rdx + rax*4]
    mov rcx, [rbp - UDE_OUT]

    cmp eax, 0x80
    jae .two
    mov [rbx + rcx], al
    inc rcx
    jmp .stored
.two:
    cmp eax, 0x800
    jae .three
    mov edx, eax
    shr edx, 6
    or edx, 0xC0
    mov [rbx + rcx], dl
    and eax, 0x3F
    or eax, 0x80
    mov [rbx + rcx + 1], al
    add rcx, 2
    jmp .stored
.three:
    cmp eax, 0x10000
    jae .four
    mov edx, eax
    shr edx, 12
    or edx, 0xE0
    mov [rbx + rcx], dl
    mov edx, eax
    shr edx, 6
    and edx, 0x3F
    or edx, 0x80
    mov [rbx + rcx + 1], dl
    and eax, 0x3F
    or eax, 0x80
    mov [rbx + rcx + 2], al
    add rcx, 3
    jmp .stored
.four:
    mov edx, eax
    shr edx, 18
    or edx, 0xF0
    mov [rbx + rcx], dl
    mov edx, eax
    shr edx, 12
    and edx, 0x3F
    or edx, 0x80
    mov [rbx + rcx + 1], dl
    mov edx, eax
    shr edx, 6
    and edx, 0x3F
    or edx, 0x80
    mov [rbx + rcx + 2], dl
    and eax, 0x3F
    or eax, 0x80
    mov [rbx + rcx + 3], al
    add rcx, 4
.stored:
    mov [rbp - UDE_OUT], rcx
    inc qword [rbp - UDE_I]
    jmp .loop

.finish:
    mov rdi, rbx
    mov rsi, [rbp - UDE_OUT]
    call str_new_heap
    push rax
    push rax                        ; twice: rsp stays 16-byte aligned
    mov rdi, rbx
    call ap_free
    pop rax
    pop rcx
    pop rbx
    leave
    ret
.oom:
    extern exc_MemoryError_type
    lea rdi, [rel exc_MemoryError_type]
    CSTRING rsi, "out of memory normalizing"
    call set_exception
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC udn_encode

;; ============================================================================
;; udn_normalize_str(rdi = PyStrObject*, esi = compatibility, edx = compose)
;;   -> rax = a new PyStrObject*, or 0 with an exception pending
;;
;; The whole of UAX #15 for one string.  An ASCII string is already in every
;; one of the four forms -- no character below U+0080 has a decomposition, a
;; combining class or a composition partner -- so it is handed straight back
;; with a reference of its own, which is what CPython does too and is by far
;; the most common case.
;; ============================================================================
UNS_STR   equ 8
UNS_K     equ 16
UNS_C     equ 24
UNS_PTR   equ 32
UNS_END   equ 40
; The struct goes LAST and its offset is derived, not picked: a hand-chosen
; one silently overlaps the scalars above it the first time UdnBuf grows, and
; the symptom is one field reading as garbage.
UNS_BUF   equ 40 + UdnBuf_size
UNS_FRAME equ UNS_BUF + 8           ; + 1 push = 80, 16-aligned
global udn_normalize_str
DEF_FUNC udn_normalize_str, UNS_FRAME
    push rbx
    mov [rbp - UNS_STR], rdi
    mov [rbp - UNS_K], rsi
    mov [rbp - UNS_C], rdx

    ; ASCII is already normalized in all four forms.
    mov rax, [rdi + PyStrObject.ob_size]
    cmp rax, [rdi + PyStrObject.ob_length]
    jne .general
    call obj_incref
    mov rax, [rbp - UNS_STR]
    pop rbx
    leave
    ret

.general:
    lea rbx, [rbp - UNS_BUF]
    mov qword [rbx + UdnBuf.data], 0
    mov qword [rbx + UdnBuf.len], 0
    mov qword [rbx + UdnBuf.cap], 0

    ; Step 1, walking the UTF-8 directly: str_cp_at would re-scan from the
    ; start for every index, which is quadratic on exactly the strings that
    ; reach here.
    mov rdi, [rbp - UNS_STR]
    lea rax, [rdi + PyStrObject.data]
    mov [rbp - UNS_PTR], rax
    add rax, [rdi + PyStrObject.ob_size]
    mov [rbp - UNS_END], rax
.decode_loop:
    mov rcx, [rbp - UNS_PTR]
    cmp rcx, [rbp - UNS_END]
    jae .decoded
    movzx eax, byte [rcx]
    test al, 0x80
    jz .one_byte
    mov edx, eax
    and edx, 0xE0
    cmp edx, 0xC0
    je .two_bytes
    mov edx, eax
    and edx, 0xF0
    cmp edx, 0xE0
    je .three_bytes
    ; four
    and eax, 0x07
    shl eax, 18
    movzx edx, byte [rcx + 1]
    and edx, 0x3F
    shl edx, 12
    or eax, edx
    movzx edx, byte [rcx + 2]
    and edx, 0x3F
    shl edx, 6
    or eax, edx
    movzx edx, byte [rcx + 3]
    and edx, 0x3F
    or eax, edx
    add qword [rbp - UNS_PTR], 4
    jmp .have_cp
.three_bytes:
    and eax, 0x0F
    shl eax, 12
    movzx edx, byte [rcx + 1]
    and edx, 0x3F
    shl edx, 6
    or eax, edx
    movzx edx, byte [rcx + 2]
    and edx, 0x3F
    or eax, edx
    add qword [rbp - UNS_PTR], 3
    jmp .have_cp
.two_bytes:
    and eax, 0x1F
    shl eax, 6
    movzx edx, byte [rcx + 1]
    and edx, 0x3F
    or eax, edx
    add qword [rbp - UNS_PTR], 2
    jmp .have_cp
.one_byte:
    inc qword [rbp - UNS_PTR]
.have_cp:
    mov rdi, rbx
    mov rsi, rax
    mov rdx, [rbp - UNS_K]
    call udn_decompose_cp
    test eax, eax
    jz .failed
    jmp .decode_loop

.decoded:
    mov rdi, rbx
    call udn_reorder
    cmp qword [rbp - UNS_C], 0
    je .encode
    mov rdi, rbx
    call udn_compose
.encode:
    mov rdi, rbx
    call udn_encode
    push rax
    push rax                        ; twice: rsp stays 16-byte aligned
    mov rdi, [rbx + UdnBuf.data]
    test rdi, rdi
    jz .no_free
    call ap_free
.no_free:
    pop rax
    pop rcx
    pop rbx
    leave
    ret

.failed:
    mov rdi, [rbx + UdnBuf.data]
    test rdi, rdi
    jz .no_free2
    call ap_free
.no_free2:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC udn_normalize_str

section .data
align 8
;; The current database: unicodenorm_tables.asm, generated from the running
;; CPython's own unicodedata.
global udn_tables_current
udn_tables_current:
    dq udn_index, 0, udn_pool, udn_pairs, 0, udn_ccc, 0
    dq udn_raw_index, 0, udn_raw_pool, udn_tags

;; The frozen Unicode 3.2 copy: ucd32_tables.asm, generated from the running
;; CPython's own unicodedata.ucd_3_2_0.
global udn_tables_ucd32
udn_tables_ucd32:
    dq ucd32_index, 0, ucd32_pool, ucd32_pairs, 0, ucd32_ccc, 0
    dq ucd32_raw_index, 0, ucd32_raw_pool, ucd32_tags

section .bss
;; Which of the two the lookups are reading.  Zero until udn_select runs, and
;; every entry point runs it first.
udn_active: resq 1
;; The database the entry point picked, held across the argument checks so the
;; two wrappers need no frame of their own.
udn_pending_tables: resq 1

section .text

extern ucd32_index
extern ucd32_index_count
extern ucd32_pool
extern ucd32_pairs
extern ucd32_pair_count
extern ucd32_ccc
extern ucd32_ccc_count
extern ucd32_raw_index
extern ucd32_raw_count
extern ucd32_raw_pool
extern ucd32_tags

;; ============================================================================
;; udn_select(rdi = a UdnTables*) -> nothing: the lookups now read that
;;   database
;;
;; The three counts are filled in here rather than in the table literals above,
;; because a `dq` of a symbol's CONTENTS is not something NASM can write: the
;; counts live in the generated files as words, not as addresses.  Doing it on
;; every call is three loads and three stores against a binary search over
;; thousands of rows.
;; ============================================================================
global udn_select
DEF_FUNC_BARE udn_select
    mov [rel udn_active], rdi
    lea rax, [rel udn_tables_current]
    cmp rdi, rax
    jne .ucd32
    mov rax, [rel udn_index_count]
    mov [rdi + UdnTables.index_count], rax
    mov rax, [rel udn_pair_count]
    mov [rdi + UdnTables.pair_count], rax
    mov rax, [rel udn_ccc_count]
    mov [rdi + UdnTables.ccc_count], rax
    mov rax, [rel udn_raw_count]
    mov [rdi + UdnTables.raw_count], rax
    ret
.ucd32:
    mov rax, [rel ucd32_index_count]
    mov [rdi + UdnTables.index_count], rax
    mov rax, [rel ucd32_pair_count]
    mov [rdi + UdnTables.pair_count], rax
    mov rax, [rel ucd32_ccc_count]
    mov [rdi + UdnTables.ccc_count], rax
    mov rax, [rel ucd32_raw_count]
    mov [rdi + UdnTables.raw_count], rax
    ret
END_FUNC udn_select

;; ============================================================================
;; unicodedata_normalize(args, nargs) -> rax = a Value
;;   -- unicodedata.normalize(form, unistr)
;;
;; The form decides two flags and nothing else, which is why one driver serves
;; all four: compatibility chooses which decomposition span to read, and
;; compose says whether step 3 runs.
;; ============================================================================
global unicodedata_normalize
DEF_FUNC_BARE unicodedata_normalize
    lea rax, [rel udn_tables_current]
    mov [rel udn_pending_tables], rax
    jmp udn_normalize_body
END_FUNC unicodedata_normalize

;; ============================================================================
;; ucd32_normalize(args, nargs) -> rax = a Value
;;   -- unicodedata.ucd_3_2_0.normalize(form, unistr)
;; ============================================================================
global ucd32_normalize
DEF_FUNC_BARE ucd32_normalize
    lea rax, [rel udn_tables_ucd32]
    mov [rel udn_pending_tables], rax
    jmp udn_normalize_body
END_FUNC ucd32_normalize

;; ============================================================================
;; udn_normalize_body(rdi = args, rsi = nargs) -> rax = a Value
;; Fails: 0
;;
;; The shared body.  The two names above are bare thunks that JUMP here, so
;; this function's own prologue is the only one and the call's alignment is
;; untouched; each names a database and nothing else.
;; ============================================================================
DEF_FUNC udn_normalize_body
    cmp rsi, 2
    jne .arity
    mov rax, [rdi]                      ; the form
    mov r10, [rdi + 8]                  ; the string
    V_TEST_PTR rax, rcx
    ja .bad_form
    test rax, rax
    jz .bad_form
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    je .form_is_str
    test qword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_STR_SUBCLASS
    jz .bad_form
.form_is_str:

    V_TEST_PTR r10, rcx
    ja .bad_str
    test r10, r10
    jz .bad_str
    mov rcx, [r10 + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    je .arg_is_str
    test qword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_STR_SUBCLASS
    jz .bad_str
.arg_is_str:

    ; "NFC", "NFD", "NFKC", "NFKD" -- four short names, so the test is the
    ; bytes rather than a table.
    lea rcx, [rax + PyStrObject.data]
    mov rdx, [rax + PyStrObject.ob_size]
    cmp byte [rcx], 'N'
    jne .bad_name
    cmp byte [rcx + 1], 'F'
    jne .bad_name
    cmp rdx, 3
    je .three_letter
    cmp rdx, 4
    jne .bad_name
    cmp byte [rcx + 2], 'K'
    jne .bad_name
    mov esi, 1                          ; compatibility
    movzx r8d, byte [rcx + 3]
    jmp .have_kind
.three_letter:
    xor esi, esi
    movzx r8d, byte [rcx + 2]
.have_kind:
    xor edx, edx
    cmp r8b, 'D'
    je .have_form
    cmp r8b, 'C'
    jne .bad_name
    mov edx, 1                          ; compose
.have_form:
    push rdx
    push rsi
    mov rdi, [rel udn_pending_tables]
    call udn_select
    pop rsi
    pop rdx
    mov rdi, r10
    call udn_normalize_str
    test rax, rax
    jz .propagate
    leave
    ret

.propagate:
    xor eax, eax
    leave
    ret
.bad_name:
    FAIL exc_ValueError_type, "invalid normalization form", .propagate
.bad_form:
    FAIL exc_TypeError_type, "normalize() argument 1 must be str", .propagate
.bad_str:
    FAIL exc_TypeError_type, "normalize() argument 2 must be str", .propagate
.arity:
    FAIL exc_TypeError_type, "normalize() takes exactly 2 arguments", .propagate
END_FUNC udn_normalize_body

;; ============================================================================
;; unicodedata_is_normalized(args, nargs) -> rax = a Value
;;   -- unicodedata.is_normalized(form, unistr)
;;
;; CPython answers this from a quick check -- a per-character NFC/NFD quick-
;; check property with a MAYBE state -- and falls back to normalising when the
;; answer is MAYBE.  Only the fallback is here: normalise and compare, which
;; is the same answer for every input and is what `test_unicodedata`'s
;; conformance run over NormalizationTest.txt needs to exist at all.  The
;; quick-check table would make it O(n) on already-normal text rather than
;; O(n) plus an allocation; nothing in the tree is hot on it yet.
;; ============================================================================
INZ_STR   equ 8
INZ_OUT   equ 16
INZ_FN    equ 24            ; which database's normalize to ask
INZ_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
global unicodedata_is_normalized
DEF_FUNC_BARE unicodedata_is_normalized
    lea rax, [rel unicodedata_normalize]
    jmp udn_is_normalized_body
END_FUNC udn_is_normalized_body

;; ============================================================================
;; ucd32_is_normalized(args, nargs) -> rax = a Value
;;   -- unicodedata.ucd_3_2_0.is_normalized(form, unistr)
;; ============================================================================
global ucd32_is_normalized
DEF_FUNC_BARE ucd32_is_normalized
    lea rax, [rel ucd32_normalize]
    jmp udn_is_normalized_body
END_FUNC ucd32_is_normalized

;; ============================================================================
;; udn_is_normalized_body(rdi = args, rsi = nargs, rax = the normalize thunk
;;   for this database) -> rax = a Value
;; Fails: 0
;;
;; The shared body, as normalize and decomposition each have one.
;; ============================================================================
DEF_FUNC udn_is_normalized_body, INZ_FRAME
    mov [rbp - INZ_FN], rax
    cmp rsi, 2
    jne .inz_arity
    mov r10, [rdi + 8]              ; the string, checked by the shared body
    mov [rbp - INZ_STR], r10
    ; Through the THUNK, not the shared body: the thunk is what names the
    ; database, and entering the body directly left udn_pending_tables holding
    ; whatever was there last -- zero on the first call, which udn_select then
    ; wrote through.
    call [rbp - INZ_FN]             ; the form is parsed and refused there
    test rax, rax
    jz .inz_propagate
    mov [rbp - INZ_OUT], rax

    ; Equal as STRINGS, not as objects: the ASCII fast path hands the input
    ; straight back, but a non-ASCII string that was already normal comes back
    ; as a new object with the same characters.  Same byte length and same
    ; bytes is the whole test -- both are UTF-8 and both are well formed.
    mov rsi, [rbp - INZ_STR]
    mov rdx, [rax + PyStrObject.ob_size]
    cmp rdx, [rsi + PyStrObject.ob_size]
    jne .inz_release_false
    lea rdi, [rax + PyStrObject.data]
    lea rsi, [rsi + PyStrObject.data]
    extern ap_memcmp
    call ap_memcmp
    push rax
    push rax                        ; twice: rsp stays 16-byte aligned
    mov rdi, [rbp - INZ_OUT]
    call obj_decref
    pop rax
    pop rcx
    test eax, eax
    jnz .inz_false
    jmp .inz_true

.inz_release_false:
    mov rdi, [rbp - INZ_OUT]
    call obj_decref
    jmp .inz_false
.inz_true:
    lea rax, [rel bool_true]
    jmp .inz_out
.inz_false:
    lea rax, [rel bool_false]
.inz_out:
    INCREF rax
    leave
    ret

.inz_propagate:
    xor eax, eax
    leave
    ret
.inz_arity:
    FAIL exc_TypeError_type, "is_normalized() takes exactly 2 arguments", .inz_propagate
END_FUNC unicodedata_is_normalized

;; ============================================================================
;; udn_raw_row_for(rdi = a code point) -> rax = the udn_raw_index row, or 0
;; ============================================================================
UDN_RAW_ROW    equ 16
UDN_RAW_CP     equ 0
UDN_RAW_TAG    equ 4
UDN_RAW_OFF    equ 8
UDN_RAW_LEN    equ 12
global udn_raw_row_for
DEF_FUNC_BARE udn_raw_row_for
    mov r11, [rel udn_active]
    mov r8, [r11 + UdnTables.raw_index]
    mov r9, [r11 + UdnTables.raw_count]
    xor rcx, rcx
.loop:
    cmp rcx, r9
    jae .none
    mov rax, r9
    sub rax, rcx
    shr rax, 1
    add rax, rcx
    lea rdx, [rax + rax]        ; as above: two 8-byte steps for a 16-byte row
    mov edx, [r8 + rdx*8 + UDN_RAW_CP]
    cmp edx, edi
    je .found
    jb .go_right
    mov r9, rax
    jmp .loop
.go_right:
    lea rcx, [rax + 1]
    jmp .loop
.found:
    lea rdx, [rax + rax]
    lea rax, [r8 + rdx*8]
    ret
.none:
    xor eax, eax
    ret
END_FUNC udn_raw_row_for

;; ============================================================================
;; unicodedata_decomposition(args, nargs) -> rax = a Value
;;   -- unicodedata.decomposition(chr)
;;
;; The mapping as the UCD writes it: "0041 0300" for a canonical one,
;; "<noBreak> 0020" for a tagged one, and the empty string when there is none.
;; It is the RAW mapping, one level deep and with the tag it was written with
;; -- which the fully expanded table cannot give back, so a second index
;; carries it.  Sixteen tags, and "<compat>" is only one of them.
;;
;; A Hangul syllable answers the EMPTY string, which is what CPython does: its
;; decomposition is arithmetic rather than a UCD mapping, and `decomposition()`
;; reports only what the file carries.  `normalize()` still decomposes one --
;; the two questions are not the same.
;; ============================================================================
UDD_LEN   equ 8
UDD_CP    equ 16
UDD_TEXT  equ 192                   ; room for a tag and eighteen fields
UDD_FRAME equ 192                   ; + 2 pushes = 208, 16-aligned
global unicodedata_decomposition
DEF_FUNC_BARE unicodedata_decomposition
    lea rax, [rel udn_tables_current]
    mov [rel udn_pending_tables], rax
    jmp udn_decomposition_body
END_FUNC unicodedata_decomposition

;; ============================================================================
;; ucd32_decomposition(args, nargs) -> rax = a Value
;;   -- unicodedata.ucd_3_2_0.decomposition(chr)
;; ============================================================================
global ucd32_decomposition
DEF_FUNC_BARE ucd32_decomposition
    lea rax, [rel udn_tables_ucd32]
    mov [rel udn_pending_tables], rax
    jmp udn_decomposition_body
END_FUNC ucd32_decomposition

;; ============================================================================
;; udn_decomposition_body(rdi = args, rsi = nargs) -> rax = a Value
;; Fails: 0
;;
;; The shared body, as normalize has one: the two names above are bare thunks
;; that JUMP here and differ only in which database they name.
;; ============================================================================
DEF_FUNC udn_decomposition_body, UDD_FRAME
    push rbx
    push r12
    push rdi
    push rsi
    mov rdi, [rel udn_pending_tables]
    call udn_select
    pop rsi
    pop rdi
    cmp rsi, 1
    jne .arity
    mov rdi, [rdi]
    call ud_one_codepoint_ext
    cmp rax, -1
    je .type
    mov [rbp - UDD_CP], rax
    mov qword [rbp - UDD_LEN], 0

    mov rdi, [rbp - UDD_CP]
    call udn_raw_row_for
    test rax, rax
    jz .finish                      ; no mapping: the empty string
    mov rbx, rax
    mov eax, [rbx + UDN_RAW_TAG]
    mov rcx, [rel udn_active]
    mov rcx, [rcx + UdnTables.tags]
    mov rsi, [rcx + rax*8]          ; "" or "<noBreak> ", with its own space
    call .udd_append_cstr

    xor r12d, r12d
.field_loop:
    cmp r12d, [rbx + UDN_RAW_LEN]
    jae .finish
    test r12d, r12d
    jz .no_space
    CSTRING rsi, " "
    call .udd_append_cstr
.no_space:
    mov eax, [rbx + UDN_RAW_OFF]
    add eax, r12d
    mov rcx, [rel udn_active]
    mov rcx, [rcx + UdnTables.raw_pool]
    mov edi, [rcx + rax*4]
    call .udd_append_hex
    inc r12d
    jmp .field_loop

.finish:
    lea rdi, [rbp - UDD_TEXT]
    mov rsi, [rbp - UDD_LEN]
    call str_new_heap
    pop r12
    pop rbx
    leave
    ret

;; Two bare helpers sharing this frame through UDD_TEXT and UDD_LEN: neither
;; allocates and neither can fail, because the buffer is sized for the longest
;; mapping the UCD carries.  They preserve rbx and r12, which the loops above
;; hold across them.
.udd_append_cstr:
    movzx eax, byte [rsi]
    test al, al
    jz .uac_done
    mov rdx, [rbp - UDD_LEN]
    mov [rbp + rdx - UDD_TEXT], al
    inc qword [rbp - UDD_LEN]
    inc rsi
    jmp .udd_append_cstr
.uac_done:
    ret

.udd_append_hex:
    ; At least four digits, upper case, as the UCD writes them.
    mov r10d, 12
    cmp edi, 0x10000
    jb .uah_loop
    mov r10d, 16
    cmp edi, 0x100000
    jb .uah_loop
    mov r10d, 20
.uah_loop:
    mov eax, edi
    mov ecx, r10d
    shr eax, cl
    and eax, 0xF
    cmp al, 10
    jb .uah_digit
    add al, 'A' - 10
    jmp .uah_store
.uah_digit:
    add al, '0'
.uah_store:
    mov rdx, [rbp - UDD_LEN]
    mov [rbp + rdx - UDD_TEXT], al
    inc qword [rbp - UDD_LEN]
    sub r10d, 4
    jns .uah_loop
    ret

.type:
    SET_EXC exc_TypeError_type, "decomposition() argument must be a unicode character"
    jmp .fail
.arity:
    SET_EXC exc_TypeError_type, "decomposition() takes exactly 1 argument"
.fail:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
END_FUNC udn_decomposition_body

;; ============================================================================
;; ud_one_codepoint_ext(rdi = a Value) -> rax = the code point, or -1
;;
;; unicodedata.asm's own ud_one_codepoint is file-local; this is the same test
;; for this file, and it also answers for a Hangul syllable, which
;; decomposition() has to handle without a table row.
;; ============================================================================
extern str_cp_at
DEF_FUNC_LOCAL ud_one_codepoint_ext
    V_TEST_PTR rdi, rax
    ja .no
    test rdi, rdi
    jz .no
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    je .is_str
    ; A str SUBCLASS is a str: CPython's unicode converter accepts one, and an
    ; exact ob_type compare refused every entry point here for it.
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_STR_SUBCLASS
    jz .no
.is_str:
    cmp qword [rdi + PyStrObject.ob_length], 1
    jne .no
    xor esi, esi
    call str_cp_at
    leave
    ret
.no:
    mov rax, -1
    leave
    ret
END_FUNC ud_one_codepoint_ext
