; sre.asm - SRE match engine for apython
; Direct u32 interpreter implementing CPython's regex bytecode
;
; Main entry: sre_match(SRE_State*, u32* pattern) -> 0/1/-1
;             sre_search(SRE_State*) -> 0/1/-1
;
; Match engine registers (within sre_match):
;   rbx = u32 *pc (pattern code pointer)
;   r12 = SRE_State*
;   r13 = char index (position in string)
;   r14 = scratch / saved across calls
;   r15 = SRE_RepeatContext* chain head

%include "macros.inc"
%include "object.inc"
%include "sre.inc"

extern ap_malloc
extern ap_free
extern ap_realloc
extern ap_memcpy
extern obj_decref
extern obj_incref
extern raise_exception
extern exc_RuntimeError_type
extern sre_getchar
extern sre_category
extern sre_charset
extern sre_at
extern sre_ascii_tolower
extern sre_unicode_tolower
extern sre_uni_isword



;; ============================================================================
;; sre_state_init(SRE_State* state, SRE_PatternObject* pattern,
;;                PyStrObject* string, i64 pos, i64 endpos,
;;                SRE_CpCache* cache) -> void
;; Initialize match state for a string.
;;
;; cache may be NULL, and is for callers that init a state repeatedly over the
;; same subject -- the scanner behind finditer is the only one.  A non-ASCII
;; subject has to be decoded to u32 for random access, which is O(len); with a
;; cache that happens once and every later state borrows the result.  NULL
;; means decode and own, which is what every other caller wants.
;; ============================================================================
SSI_ENDPOS   equ 8       ; endpos (ASCII path); reused as state ptr (Unicode path)
SSI_BYTELEN  equ 16      ; byte length (Unicode path only)
SSI_UENDPOS  equ 24      ; endpos saved before clobber (Unicode path only)
SSI_CACHE    equ 32      ; SRE_CpCache*, or 0
SSI_FRAME    equ 48         ; + 4 pushes = 80

DEF_FUNC sre_state_init, SSI_FRAME
    push rbx
    push r12
    push r13
    push r14

    mov rbx, rdi               ; state
    mov r12, rsi               ; pattern
    mov r13, rdx               ; string
    mov r14, rcx               ; pos
    mov [rbp - SSI_ENDPOS], r8 ; save endpos
    mov [rbp - SSI_CACHE], r9  ; save the codepoint cache, or 0

    ; Zero out the state
    mov rdi, rbx
    xor eax, eax
    mov ecx, SRE_State_size / 8
.zero_loop:
    mov [rdi], rax
    add rdi, 8
    dec ecx
    jnz .zero_loop

    ; The subject has to BE a string before it is read as one.  The entry
    ; points in sre_pattern.asm check only their argument COUNT and hand
    ; args[0] straight through, so `p.match(5)` reached the dereference below
    ; with an int immediate and read PyStrObject.ob_size out of address 5.
    ; One call here covers every method that builds a state; finditer builds
    ; a scanner instead and calls it for itself.
    mov rdi, r13
    mov rsi, r12
    call sre_require_subject

    ; Set basic fields
    mov [rbx + SRE_State.pattern], r12
    mov [rbx + SRE_State.string_obj], r13

    ; Get the subject's data.  bytes keeps it at +24 and str at +40, and both
    ; put the length at +16 -- so only the data pointer differs.
    mov rax, [r12 + SRE_PatternObject.is_bytes]
    mov [rbx + SRE_State.is_bytes], eax
    test rax, rax
    jz .ssi_str_data
    call sre_subject_data       ; r13 -> rax = data, rdx = length
    mov [rbx + SRE_State.str_begin], rax
    lea rdx, [rax + rdx]
    mov [rbx + SRE_State.str_end], rdx
    jmp .ssi_have_data
.ssi_str_data:
    lea rax, [r13 + PyStrObject.data]
    mov [rbx + SRE_State.str_begin], rax
    mov rcx, [r13 + PyStrObject.ob_size]
    lea rdx, [rax + rcx]
    mov [rbx + SRE_State.str_end], rdx
.ssi_have_data:

    ; Set flags from pattern
    mov eax, [r12 + SRE_PatternObject.flags]
    mov [rbx + SRE_State.flags], eax
    mov dword [rbx + SRE_State.match_all], 0
    mov dword [rbx + SRE_State.match_depth], 0

    ; Determine if ASCII or needs Unicode codepoint decode.
    ;
    ; The str already knows: ob_size counts bytes and ob_length code points,
    ; and they are equal exactly when every byte is below 0x80.  This used to
    ; scan the whole subject a byte at a time to learn the same thing, on
    ; every single call -- so `pat.match(s, pos)` cost O(len(s)) however
    ; little of it the match looked at, and any parser driving a regex
    ; forward through a string was quadratic.  json.loads spent 599 ms on
    ; 95 KB where CPython spent 0.5.
    ;
    ; A BYTES subject is byte-indexed by definition, so it takes the ASCII
    ; path whatever the values are: \xff in bytes is one element, not the
    ; start of a sequence.  It has no ob_length to consult, which is why the
    ; comparison sits behind the is_bytes test rather than beside it.
    mov dword [rbx + SRE_State.charsize], 1  ; assume ASCII
    mov qword [rbx + SRE_State.codepoint_buf], 0
    cmp dword [rbx + SRE_State.is_bytes], 0
    jne .ascii_done
    mov rax, [r13 + PyStrObject.ob_size]
    cmp rax, [r13 + PyStrObject.ob_length]
    jne .need_unicode          ; an empty str has both at 0 and lands here too

.ascii_done:
    ; Pure ASCII: str_begin/str_end are byte ptrs, charsize=1
    ; String length in chars = byte length.  ob_size is at the same offset in
    ; bytes and str, so this reads either.
    mov rax, [r13 + PyStrObject.ob_size]

    ; Clamp effective length with endpos
    mov rcx, [rbp - SSI_ENDPOS] ; endpos
    test rcx, rcx
    jl .ascii_endpos_done
    cmp rcx, rax
    jge .ascii_endpos_done
    mov rax, rcx               ; effective length = endpos
.ascii_endpos_done:
    mov [rbx + SRE_State.codepoint_len], rax
    ; Update str_end to reflect endpos
    mov rcx, [rbx + SRE_State.str_begin]
    add rcx, rax
    mov [rbx + SRE_State.str_end], rcx

    ; Clamp pos
    test r14, r14
    jge .pos_ok
    xor r14d, r14d
.pos_ok:
    cmp r14, rax
    jle .pos_ok2
    mov r14, rax
.pos_ok2:
    mov [rbx + SRE_State.str_pos], r14
    mov [rbx + SRE_State.str_start], r14
    mov [rbx + SRE_State.original_pos], r14

    jmp .init_marks

.need_unicode:
    mov dword [rbx + SRE_State.charsize], 4

    ; A cache already holding this subject's decode?  Borrow it: the scanner
    ; that owns the cache outlives every state built from it, and the subject
    ; is an immutable str, so the buffer can neither dangle nor go stale.
    ; r8 carries the codepoint count into the endpos clamp on both paths.
    mov rax, [rbp - SSI_CACHE]
    test rax, rax
    jz .nu_decode
    mov rdx, [rax + SRE_CpCache.buf]
    test rdx, rdx
    jz .nu_decode
    ; ...and of THIS subject.  A scanner's cache only ever sees one, but the
    ; module-level cache the pattern methods share sees a different string
    ; every other call.
    mov rcx, [rax + SRE_CpCache.subject]
    cmp rcx, r13
    jne .nu_evict
    mov [rbx + SRE_State.codepoint_buf], rdx
    mov [rbx + SRE_State.cpcache], rax      ; released by sre_state_fini
    inc qword [rax + SRE_CpCache.borrows]
    mov r8, [rax + SRE_CpCache.len]
    ; .utf8_clamp reads endpos from SSI_UENDPOS, which only the decode path
    ; below writes -- it moves endpos there because it needs SSI_ENDPOS for
    ; the state pointer.  Nothing has been clobbered on this path, so just
    ; put it where the clamp looks.
    mov rax, [rbp - SSI_ENDPOS]
    mov [rbp - SSI_UENDPOS], rax
    jmp .utf8_clamp            ; owns_cpbuf stays 0: the cache owns it

.nu_evict:
    ; A different subject.  Evicting is a FREE, and a scan that is still
    ; running holds a borrowed pointer into this buffer -- sub, subn, split
    ; and findall all run user code between matches, so a nested regex on
    ; another subject arrives here with the outer one live.  Freeing it there
    ; left the outer scan indexing released memory and answering from it.
    ;
    ; So: evict only when nothing is reading, and otherwise leave the cache
    ; alone and decode privately below, which is what the caller did before
    ; the cache existed.
    cmp qword [rax + SRE_CpCache.borrows], 0
    jne .nu_decode_private
    mov rdi, rdx
    push rax
    call ap_free
    pop rax
    mov qword [rax + SRE_CpCache.buf], 0
    mov rdi, [rax + SRE_CpCache.subject]
    mov qword [rax + SRE_CpCache.subject], 0
    push rax
    call obj_decref
    pop rax
    jmp .nu_decode

.nu_decode_private:
    ; Decode for this state alone, and do not hand it to the cache below.
    mov qword [rbp - SSI_CACHE], 0

.nu_decode:
    ; UTF-8 decode to u32 codepoint array
    mov rdi, [rbx + SRE_State.str_begin]
    mov rsi, [r13 + PyStrObject.ob_size]
    mov rax, [rbp - SSI_ENDPOS] ; save endpos before clobbering
    mov [rbp - SSI_UENDPOS], rax ; endpos in Unicode-path slot
    mov [rbp - SSI_ENDPOS], rbx  ; save state ptr (reuses slot)
    mov [rbp - SSI_BYTELEN], rsi ; save byte length

    ; Allocate codepoint buffer (worst case: byte_len codepoints)
    lea rdi, [rsi*4]           ; u32 per codepoint
    call ap_malloc
    mov rbx, [rbp - SSI_ENDPOS] ; restore state (slot reused)
    mov [rbx + SRE_State.codepoint_buf], rax

    ; Decode UTF-8
    mov rdi, [rbx + SRE_State.str_begin]
    mov rsi, [rbp - SSI_BYTELEN] ; byte length
    mov rdx, rax               ; output buffer
    xor ecx, ecx               ; byte index
    xor r8d, r8d               ; codepoint index

.utf8_decode:
    cmp rcx, rsi
    jge .utf8_done
    movzx eax, byte [rdi + rcx]
    cmp al, 0x80
    jb .utf8_1byte
    cmp al, 0xe0
    jb .utf8_2byte
    cmp al, 0xf0
    jb .utf8_3byte
    jmp .utf8_4byte

.utf8_1byte:
    mov [rdx + r8*4], eax
    inc rcx
    inc r8
    jmp .utf8_decode

.utf8_2byte:
    and eax, 0x1f
    shl eax, 6
    movzx r9d, byte [rdi + rcx + 1]
    and r9d, 0x3f
    or eax, r9d
    mov [rdx + r8*4], eax
    add rcx, 2
    inc r8
    jmp .utf8_decode

.utf8_3byte:
    and eax, 0x0f
    shl eax, 12
    movzx r9d, byte [rdi + rcx + 1]
    and r9d, 0x3f
    shl r9d, 6
    or eax, r9d
    movzx r9d, byte [rdi + rcx + 2]
    and r9d, 0x3f
    or eax, r9d
    mov [rdx + r8*4], eax
    add rcx, 3
    inc r8
    jmp .utf8_decode

.utf8_4byte:
    and eax, 0x07
    shl eax, 18
    movzx r9d, byte [rdi + rcx + 1]
    and r9d, 0x3f
    shl r9d, 12
    or eax, r9d
    movzx r9d, byte [rdi + rcx + 2]
    and r9d, 0x3f
    shl r9d, 6
    or eax, r9d
    movzx r9d, byte [rdi + rcx + 3]
    and r9d, 0x3f
    or eax, r9d
    mov [rdx + r8*4], eax
    add rcx, 4
    inc r8
    jmp .utf8_decode

.utf8_done:
    ; r8 is the full codepoint count, before any endpos clamp -- which is what
    ; the cache must hold, since endpos narrows a single match and the next
    ; one may not narrow at all.
    mov qword [rbx + SRE_State.owns_cpbuf], 1
    mov rax, [rbp - SSI_CACHE]
    test rax, rax
    jz .utf8_clamp
    mov rdx, [rbx + SRE_State.codepoint_buf]
    mov [rax + SRE_CpCache.buf], rdx
    mov [rax + SRE_CpCache.len], r8
    ; The subject is kept alive by the cache: its ADDRESS is the key, and a
    ; freed string whose address is reused would otherwise read as a hit.
    mov [rax + SRE_CpCache.subject], r13
    push rax
    push r8
    mov rdi, r13
    call obj_incref
    pop r8
    pop rax
    mov qword [rbx + SRE_State.owns_cpbuf], 0   ; the cache owns it now
    ; ...and this state is READING it, so it counts as a borrower like any
    ; other.  Only the borrow path registered, so the state that filled the
    ; cache was invisible to the eviction check -- and a nested scan on
    ; another subject freed the buffer the outer one was still indexing.
    mov [rbx + SRE_State.cpcache], rax
    inc qword [rax + SRE_CpCache.borrows]

.utf8_clamp:
    ; Clamp codepoint_len with endpos
    mov rcx, [rbp - SSI_UENDPOS] ; endpos (saved before clobber)
    test rcx, rcx
    jl .uni_endpos_done
    cmp rcx, r8
    jge .uni_endpos_done
    mov r8, rcx                ; effective length = endpos
.uni_endpos_done:
    mov [rbx + SRE_State.codepoint_len], r8

    ; Clamp pos for Unicode
    test r14, r14
    jge .upos_ok
    xor r14d, r14d
.upos_ok:
    cmp r14, r8
    jle .upos_ok2
    mov r14, r8
.upos_ok2:
    mov [rbx + SRE_State.str_pos], r14
    mov [rbx + SRE_State.str_start], r14
    mov [rbx + SRE_State.original_pos], r14

.init_marks:
    ; Allocate marks array.  Every reader here already treats -1 as "this
    ; group never matched" -- and every one of them was reading whatever
    ; ap_malloc left behind, because nothing ever wrote it.  marks_size is a
    ; high-water mark, not a count of the marks that were set, so a group
    ; below it that the match never reached is a hole, and the hole read as
    ; the allocator's zeros: span (0, 0) and an empty string, where CPython
    ; answers (-1, -1) and None.
    mov edi, SRE_MARKS_INITIAL * 8
    call ap_malloc
    mov [rbx + SRE_State.marks], rax
    mov qword [rbx + SRE_State.marks_count], SRE_MARKS_INITIAL
    mov rdi, rbx
    call sre_state_reset_marks

    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC sre_state_init

;; ============================================================================
;; sre_require_subject(rdi = the subject Value) -- returns, or raises
;;
;; A bytes-like subject is a different refusal from "that is not a string":
;; the pattern is a str pattern, and CPython says so.  Both are TypeError.
;; ============================================================================
global sre_require_subject
DEF_FUNC sre_require_subject
    ; rdi = the subject Value, rsi = the pattern object (0 = a str pattern)
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    extern str_type
extern bytes_new
extern ap_memcpy
    V_TEST_PTR rdi, rax
    ja .srs_not_string
    test rdi, rdi
    jz .srs_not_string
    mov rax, [rdi + PyObject.ob_type]

    ; Which kind the pattern wants.
    xor r8d, r8d
    test r12, r12
    jz .srs_have_kind
    mov r8, [r12 + SRE_PatternObject.is_bytes]
.srs_have_kind:

    lea rcx, [rel str_type]
    cmp rax, rcx
    je .srs_is_str
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_STR_SUBCLASS
    jnz .srs_is_str

    extern bytes_type
    extern bytearray_type
    lea rcx, [rel bytes_type]
    cmp rax, rcx
    je .srs_is_bytes
    lea rcx, [rel bytearray_type]
    cmp rax, rcx
    je .srs_is_bytes
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_BYTES_SUBCLASS
    jnz .srs_is_bytes
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_BYTEARRAY_SUBCLASS
    jnz .srs_is_bytes
    jmp .srs_not_string

.srs_is_str:
    test r8, r8
    jnz .srs_want_bytes
    jmp .srs_ok
.srs_is_bytes:
    test r8, r8
    jz .srs_want_str
    jmp .srs_ok

.srs_ok:
    pop r12
    pop rbx
    leave
    ret

.srs_want_str:
    extern exc_TypeError_type
    RAISE exc_TypeError_type, "cannot use a string pattern on a bytes-like object"
.srs_want_bytes:
    RAISE exc_TypeError_type, "cannot use a bytes pattern on a string-like object"

.srs_not_string:
    extern raise_type_error_with_name
    mov rsi, rbx
    CSTRING rdi, `expected string or bytes-like object, got '\x01'`
    call raise_type_error_with_name     ; does not return
END_FUNC sre_require_subject

;; ============================================================================
;; sre_subject_data(r13 = the subject) -> rax = the data, rdx = its length
;;
;; bytes keeps its data inline at +24 and a bytearray keeps it out of line, so
;; the two need different reads; str is handled by the caller, which knows it
;; is not here.  Nothing is copied: the state points into the object, which
;; the caller holds for the length of the match.
;; ============================================================================
global sre_subject_data
DEF_FUNC sre_subject_data
    mov rax, [r13 + PyObject.ob_type]
    lea rcx, [rel bytearray_type]
    cmp rax, rcx
    je .ssd_bytearray
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_BYTEARRAY_SUBCLASS
    jnz .ssd_bytearray
    lea rax, [r13 + PyBytesObject.data]
    mov rdx, [r13 + PyBytesObject.ob_size]
    leave
    ret
.ssd_bytearray:
    extern bytearray_data
    mov rdi, r13
    call bytearray_data         ; -> rax = the buffer, never NULL
    mov rdx, [r13 + PyByteArrayObject.ob_size]
    leave
    ret
END_FUNC sre_subject_data

;; ============================================================================
;; sre_new_slice(rdi = the data, rsi = its length, edx = 1 for bytes)
;;   -> rax = a str or a bytes, edx = TAG_PTR
;;
;; Every result the engine builds goes through here, so the kind is decided in
;; one place rather than at each of the seventeen sites that used to call
;; str_new_heap directly.
;; ============================================================================
global sre_new_slice
DEF_FUNC sre_new_slice
    test edx, edx
    jnz .sns_bytes
    extern str_new_heap
    call str_new_heap
    mov edx, TAG_PTR
    leave
    ret
.sns_bytes:
    push rdi
    push rsi
    mov rdi, rsi
    extern bytes_new
    call bytes_new
    pop rdx                     ; length
    pop rsi                     ; source
    test rax, rax
    jz .sns_fail
    push rax
    sub rsp, 8
    lea rdi, [rax + PyBytesObject.data]
    extern ap_memcpy
    call ap_memcpy
    add rsp, 8
    pop rax
    mov edx, TAG_PTR
    leave
    ret
.sns_fail:
    xor eax, eax
    xor edx, edx
    leave
    ret
END_FUNC sre_new_slice

;; ============================================================================
;; sre_concat(rdi = a Value, rsi = a Value, edx = 1 for bytes) -> a Value
;;
;; str_concat for one kind and bytes concatenation for the other.  Both take
;; over neither reference: the caller owns what it passed in, as str_concat
;; has it.
;; ============================================================================
SCC_A     equ 8
SCC_B     equ 16
SCC_ADATA equ 24
SCC_ALEN  equ 32
SCC_BDATA equ 40
SCC_BLEN  equ 48
SCC_OUT   equ 56
SCC_FRAME equ 64            ; + 0 pushes = 64
global sre_concat
DEF_FUNC sre_concat, SCC_FRAME
    test edx, edx
    jnz .scc_bytes
    ; str_concat's message is the one `'a' + 5` gets; CPython reports this
    ; from the join that assembles the result, and names the item.
    mov [rbp - SCC_B], rsi
    V_TEST_PTR rsi, rax
    ja .scc_str_type_error
    test rsi, rsi
    jz .scc_str_type_error
    mov rax, [rsi + PyObject.ob_type]
    extern str_type
    lea rcx, [rel str_type]
    cmp rax, rcx
    jne .scc_str_type_error
    extern str_concat
    call str_concat
    leave
    ret
.scc_str_type_error:
    mov rsi, [rbp - SCC_B]
    lea rdi, [rel scc_notstr]
    extern raise_type_error_with_name
    call raise_type_error_with_name     ; does not return
.scc_bytes:
    ; Both operands used to be dereferenced as bytes objects, and one of them
    ; is whatever a callable replacement returned: `re.sub(b'a', lambda m: 5,
    ; b'aba')` read PyBytesObject.ob_size off an int immediate.  The str arm
    ; delegates its check to str_concat; this one makes its own -- and takes
    ; the data through bytes_like_ptr_len, which is what lets a bytearray
    ; replacement work, as it does in CPython.
    mov [rbp - SCC_A], rdi
    mov [rbp - SCC_B], rsi
    extern bytes_like_ptr_len
    call bytes_like_ptr_len     ; rdi, the left
    test ecx, ecx
    jz .scc_type_error
    mov [rbp - SCC_ADATA], rax
    mov [rbp - SCC_ALEN], r10
    mov rdi, [rbp - SCC_B]
    call bytes_like_ptr_len
    test ecx, ecx
    jz .scc_type_error
    mov [rbp - SCC_BDATA], rax
    mov [rbp - SCC_BLEN], r10

    mov rdi, [rbp - SCC_ALEN]
    add rdi, [rbp - SCC_BLEN]
    call bytes_new
    test rax, rax
    jz .scc_fail
    mov [rbp - SCC_OUT], rax
    lea rdi, [rax + PyBytesObject.data]
    mov rsi, [rbp - SCC_ADATA]
    mov rdx, [rbp - SCC_ALEN]
    call ap_memcpy
    mov rax, [rbp - SCC_OUT]
    lea rdi, [rax + PyBytesObject.data]
    add rdi, [rbp - SCC_ALEN]
    mov rsi, [rbp - SCC_BDATA]
    mov rdx, [rbp - SCC_BLEN]
    call ap_memcpy
    mov rax, [rbp - SCC_OUT]
    mov edx, TAG_PTR
    leave
    ret
.scc_fail:
    xor eax, eax
    xor edx, edx
    leave
    ret
.scc_type_error:
    ; CPython reports this from the join that builds the result, naming the
    ; offending type: "sequence item 0: expected a bytes-like object, int
    ; found".  The item index is not knowable here; the rest is.
    mov rsi, [rbp - SCC_B]
    lea rdi, [rel scc_notbytes]
    extern raise_type_error_with_name
    call raise_type_error_with_name     ; does not return
END_FUNC sre_concat

section .rodata
scc_notbytes:
    db "sequence item 0: expected a bytes-like object, ", 1, " found", 0
scc_notstr:
    db "sequence item 0: expected str instance, ", 1, " found", 0
section .text

;; ============================================================================
;; sre_empty(edx = 1 for bytes) -> rax = "" or b"", edx = TAG_PTR
;; The seed a join or a substitution starts from.
;; ============================================================================
global sre_empty
DEF_FUNC sre_empty
    test edx, edx
    jnz .se_bytes
    CSTRING rdi, ""
    extern str_from_cstr_heap
    call str_from_cstr_heap
    mov edx, TAG_PTR
    leave
    ret
.se_bytes:
    xor edi, edi
    call bytes_new
    mov edx, TAG_PTR
    leave
    ret
END_FUNC sre_empty

;; ============================================================================
;; sre_state_fini(SRE_State* state)
;; Clean up match state.
;; ============================================================================
DEF_FUNC sre_state_fini, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi

    ; Free marks array
    mov rdi, [rbx + SRE_State.marks]
    test rdi, rdi
    jz .no_marks
    call ap_free
.no_marks:

    ; Let go of a cache this state was reading, so it may be evicted again.
    mov rax, [rbx + SRE_State.cpcache]
    test rax, rax
    jz .no_borrow
    mov qword [rbx + SRE_State.cpcache], 0
    dec qword [rax + SRE_CpCache.borrows]
.no_borrow:

    ; Free the codepoint buffer, unless it is borrowed from a cache that
    ; outlives this state.
    cmp qword [rbx + SRE_State.owns_cpbuf], 0
    je .no_cp
    mov rdi, [rbx + SRE_State.codepoint_buf]
    test rdi, rdi
    jz .no_cp
    call ap_free
.no_cp:

    pop rbx
    leave
    ret
END_FUNC sre_state_fini

;; ============================================================================
;; sre_state_reset_marks(SRE_State* state)
;;
;; Every attempt at a new starting position begins here, and so does the
;; state's own construction.  The whole array goes back to -1: clearing only
;; marks_size would leave the values a failed attempt wrote, and the next
;; attempt's marks_size can rise back over them.
;; ============================================================================
global sre_state_reset_marks
DEF_FUNC_BARE sre_state_reset_marks
    mov qword [rdi + SRE_State.marks_size], 0
    mov qword [rdi + SRE_State.lastmark], -1
    mov qword [rdi + SRE_State.lastindex], -1
    mov qword [rdi + SRE_State.repeat_ctx], 0
    mov rax, [rdi + SRE_State.marks]
    test rax, rax
    jz .srm_done
    mov rcx, [rdi + SRE_State.marks_count]
.srm_loop:
    test rcx, rcx
    jz .srm_done
    dec rcx
    mov qword [rax + rcx*8], -1
    jmp .srm_loop
.srm_done:
    ret
END_FUNC sre_state_reset_marks

;; ============================================================================
;; sre_state_set_mark(SRE_State* state, i64 mark_id, i64 pos)
;; Set a mark (group boundary) in the state.
;; ============================================================================
SRE_MAX_MARKS equ 4096
DEF_FUNC sre_state_set_mark, 8            ; 1 pushes, so rsp is 16-aligned
    ; rdi = state, rsi = mark_id, rdx = pos
    push rbx
    mov rbx, rdi

    ; A group index out of a crafted pattern is unbounded, and growing to
    ; twice it asks the allocator for whatever it says.  No compiled pattern
    ; has a thousand groups; CPython's own limit is 100 in a single pattern.
    cmp rsi, SRE_MAX_MARKS
    jae .mark_refuse

    ; Ensure marks array is large enough
    mov rcx, [rbx + SRE_State.marks_count]
    cmp rsi, rcx
    jb .mark_fits

    ; Grow marks array
    lea rdi, [rsi + 1]
    shl rdi, 1                 ; double requested size
    mov r8, [rbx + SRE_State.marks_count]   ; the old count, for the fill
    mov [rbx + SRE_State.marks_count], rdi
    shl rdi, 3                 ; * 8 bytes per mark
    push rsi
    push rdx
    push r8
    push r8                     ; a pair, so the call stays 16-byte aligned
    mov rsi, rdi               ; new size
    mov rdi, [rbx + SRE_State.marks]
    call ap_realloc
    pop r8
    pop r8
    pop rdx
    pop rsi
    mov [rbx + SRE_State.marks], rax
    ; The new tail is uninitialised, and it has to read as "never matched".
    mov rcx, [rbx + SRE_State.marks_count]
.mark_fill:
    cmp r8, rcx
    jge .mark_fits
    mov qword [rax + r8*8], -1
    inc r8
    jmp .mark_fill

.mark_fits:
    ; Set mark
    mov rax, [rbx + SRE_State.marks]
    mov [rax + rsi*8], rdx

    ; Update lastmark
    cmp rsi, [rbx + SRE_State.lastmark]
    jle .no_update_lastmark
    mov [rbx + SRE_State.lastmark], rsi
.no_update_lastmark:

    ; Update marks_size
    lea rcx, [rsi + 1]
    cmp rcx, [rbx + SRE_State.marks_size]
    jle .no_update_size
    mov [rbx + SRE_State.marks_size], rcx
.no_update_size:

    ; Update lastindex.  CPython sets it on the *closing* mark of a group and
    ; on no other -- `if (i & 1) state->lastindex = i/2 + 1` -- so mark 1
    ; closes group 1.  Setting it on every mark from 2 up, at i/2, named the
    ; wrong group by one and never named group 1 at all; lastgroup, which
    ; indexes the pattern's indexgroup tuple with it, was therefore always
    ; None.
    test rsi, 1
    jz .done
    mov rax, rsi
    shr rax, 1
    inc rax                     ; group = mark_id / 2 + 1
    mov [rbx + SRE_State.lastindex], rax

.done:
    pop rbx
    leave
    ret

.mark_refuse:
    ; Nothing to set, and nothing to say: a match either succeeds or does
    ; not, and this one will not.  The engine treats an unset mark as -1
    ; already, so leaving it alone is the same answer as never reaching here.
    pop rbx
    leave
    ret
END_FUNC sre_state_set_mark

;; ============================================================================
;; sre_state_get_mark(SRE_State* state, i64 mark_id) -> i64 pos (-1 if unset)
;; ============================================================================
DEF_FUNC_BARE sre_state_get_mark
    ; rdi = state, rsi = mark_id
    cmp rsi, [rdi + SRE_State.marks_size]
    jge .unset
    mov rax, [rdi + SRE_State.marks]
    mov rax, [rax + rsi*8]
    ret
.unset:
    mov rax, -1
    ret
END_FUNC sre_state_get_mark

;; ============================================================================
;; sre_string_len(SRE_State* state) -> i64
;; Get string length in characters.
;; ============================================================================
DEF_FUNC_BARE sre_string_len
    mov rax, [rdi + SRE_State.codepoint_buf]
    test rax, rax
    jnz .unicode_len
    ; ASCII: byte length
    mov rax, [rdi + SRE_State.str_end]
    sub rax, [rdi + SRE_State.str_begin]
    ret
.unicode_len:
    mov rax, [rdi + SRE_State.codepoint_len]
    ret
END_FUNC sre_string_len

;; ============================================================================
;; sre_match(SRE_State* state, u32* pattern) -> 0/1
;; Core recursive match engine.
;;
;; Frame layout constants
;; ============================================================================
;; sre_match(rdi = state, rsi = pattern, edx = toplevel)
;;
;; toplevel says whether a SUCCESS reached from here is the whole pattern's.
;; It is not: a repeat's body, a lookaround's body and an atomic group's body
;; are each compiled as their own sub-pattern ending in SUCCESS, so the checks
;; that belong to the overall match -- fullmatch's "and it reaches the end",
;; and must_advance -- have to skip them.  Without it re.fullmatch('a*', 'aa')
;; was None: the body's SUCCESS at position 1 was tested against the end of
;; the string and failed, so the repeat could never take a step.
SM_STATE     equ 8
SM_PATTERN   equ 16
SM_TOPLEVEL  equ 24
SM_LASTPOS   equ 32     ; the repeat's last_pos, kept across a body attempt
SM_COUNT     equ 40     ; MAX_UNTIL's ctx->count, kept across a body attempt
SM_PR_SKIP   equ 48     ; POSSESSIVE_REPEAT: skip, min, max, count, the
SM_PR_MIN    equ 56     ; marks saved around one iteration, and the
SM_PR_MAX    equ 64     ; position it started from -- all live across
SM_PR_COUNT  equ 72     ; a body sub-match
SM_PR_MARKS  equ 80
SM_PR_START  equ 88
SM_MFRAME    equ 104            ; + 5 pushes = 144, 16-aligned

DEF_FUNC sre_match, SM_MFRAME
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov [rbp - SM_STATE], rdi
    mov [rbp - SM_PATTERN], rsi
    mov [rbp - SM_TOPLEVEL], edx
    mov r12, rdi               ; r12 = state
    mov rbx, rsi               ; rbx = pc (pattern pointer)
    mov r13, [rdi + SRE_State.str_pos]  ; r13 = current pos
    mov r15, [rdi + SRE_State.repeat_ctx]  ; r15 = repeat ctx

    ; Check recursion depth limit
    mov eax, [r12 + SRE_State.match_depth]
    cmp eax, SRE_MAX_RECURSION
    jge .recursion_error
    inc dword [r12 + SRE_State.match_depth]

.dispatch:
    ; The program counter has to be inside the pattern.  The opcode was
    ; bounded and the pc never was, so a crafted program whose last word is
    ; not SUCCESS or FAILURE simply walked off the end of the code array and
    ; kept dispatching on whatever followed it.  _sre.compile() does not
    ; validate its input -- that is the private API test_sre.py feeds by hand,
    ; and the one CPython segfaults on -- so the engine has to.
    mov rax, [r12 + SRE_State.pattern]
    test rax, rax
    jz .pc_unchecked            ; no pattern object: an internal sub-match
    mov rcx, [rax + SRE_PatternObject.code]
    mov rdx, [rax + SRE_PatternObject.code_len]
    shl rdx, 2                  ; words to bytes
    add rdx, rcx                ; one past the end
    cmp rbx, rcx
    jb .op_failure
    cmp rbx, rdx
    jae .op_failure
.pc_unchecked:

    mov eax, [rbx]             ; opcode
    add rbx, 4                 ; advance past opcode

    ; Jump table dispatch
    cmp eax, SRE_OP_COUNT
    jae .op_failure

    lea rcx, [rel .op_table]
    jmp [rcx + rax*8]

    align 8
.op_table:
    dq .op_failure              ; 0  FAILURE
    dq .op_success              ; 1  SUCCESS
    dq .op_any                  ; 2  ANY
    dq .op_any_all              ; 3  ANY_ALL
    dq .op_assert               ; 4  ASSERT
    dq .op_assert_not           ; 5  ASSERT_NOT
    dq .op_at                   ; 6  AT
    dq .op_branch               ; 7  BRANCH
    dq .op_category             ; 8  CATEGORY
    dq .op_charset              ; 9  CHARSET
    dq .op_bigcharset           ; 10 BIGCHARSET
    dq .op_groupref             ; 11 GROUPREF
    dq .op_groupref_exists      ; 12 GROUPREF_EXISTS
    dq .op_in                   ; 13 IN
    dq .op_info                 ; 14 INFO
    dq .op_jump                 ; 15 JUMP
    dq .op_literal              ; 16 LITERAL
    dq .op_mark                 ; 17 MARK
    dq .op_max_until            ; 18 MAX_UNTIL
    dq .op_min_until            ; 19 MIN_UNTIL
    dq .op_not_literal           ; 20 NOT_LITERAL
    dq .op_negate               ; 21 NEGATE (only inside IN sets)
    dq .op_range                ; 22 RANGE (only inside IN sets)
    dq .op_repeat               ; 23 REPEAT
    dq .op_repeat_one           ; 24 REPEAT_ONE
    dq .op_subpattern           ; 25 SUBPATTERN
    dq .op_min_repeat_one       ; 26 MIN_REPEAT_ONE
    dq .op_atomic_group         ; 27 ATOMIC_GROUP
    dq .op_possessive_repeat    ; 28 POSSESSIVE_REPEAT
    dq .op_possessive_repeat_one ; 29 POSSESSIVE_REPEAT_ONE
    dq .op_groupref_ignore      ; 30 GROUPREF_IGNORE
    dq .op_in_ignore            ; 31 IN_IGNORE
    dq .op_literal_ignore       ; 32 LITERAL_IGNORE
    dq .op_not_literal_ignore   ; 33 NOT_LITERAL_IGNORE
    dq .op_groupref_ignore      ; 34 GROUPREF_LOC_IGNORE (same as ignore)
    dq .op_in_ignore            ; 35 IN_LOC_IGNORE
    dq .op_literal_ignore       ; 36 LITERAL_LOC_IGNORE
    dq .op_not_literal_ignore   ; 37 NOT_LITERAL_LOC_IGNORE
    dq .op_groupref_uni_ignore  ; 38 GROUPREF_UNI_IGNORE
    dq .op_in_uni_ignore        ; 39 IN_UNI_IGNORE
    dq .op_literal_uni_ignore   ; 40 LITERAL_UNI_IGNORE
    dq .op_not_literal_uni_ignore ; 41 NOT_LITERAL_UNI_IGNORE
    dq .op_range                ; 42 RANGE_UNI_IGNORE (handled in charset)

; --- Opcode implementations ---

.op_failure:
    xor eax, eax
    jmp .return

.op_success:
    ; Only the pattern's own SUCCESS answers to these; a body's does not.
    cmp dword [rbp - SM_TOPLEVEL], 0
    jz .op_success_ok

    ; Check fullmatch: if match_all, pos must == string_len
    cmp dword [r12 + SRE_State.match_all], 0
    jz .os_must_advance
    mov rdi, r12
    call sre_string_len
    cmp r13, rax
    jne .op_failure

.os_must_advance:
    ; The scanning methods set must_advance after an empty match and search
    ; the same position again.  An empty match AT that position is what they
    ; already have, so it is refused here -- which makes the engine keep
    ; backtracking, and is how '.*?' answers 'a' the second time round rather
    ; than '' for ever.
    cmp dword [r12 + SRE_State.must_advance], 0
    jz .op_success_ok
    cmp r13, [r12 + SRE_State.search_origin]
    je .op_failure

.op_success_ok:
    ; Save final position in state
    mov [r12 + SRE_State.str_pos], r13
    mov eax, 1
    jmp .return

.op_any:
    ; Match any character except newline
    mov rdi, r12
    call sre_string_len
    cmp r13, rax
    jge .op_failure
    mov rdi, r12
    mov rsi, r13
    call sre_getchar
    cmp eax, 0x0a              ; '\n'
    je .op_failure
    inc r13
    jmp .dispatch

.op_any_all:
    ; Match any character including newline
    mov rdi, r12
    call sre_string_len
    cmp r13, rax
    jge .op_failure
    inc r13
    jmp .dispatch

.op_at:
    ; AT at_code
    mov edx, [rbx]             ; at_code
    add rbx, 4
    mov rdi, r12
    mov rsi, r13
    call sre_at
    test eax, eax
    jz .op_failure
    jmp .dispatch

.op_literal:
    ; LITERAL ch — match exact character
    mov rdi, r12
    call sre_string_len
    cmp r13, rax
    jge .op_failure
    mov r14d, [rbx]            ; expected char
    add rbx, 4
    mov rdi, r12
    mov rsi, r13
    call sre_getchar
    cmp eax, r14d
    jne .op_failure
    inc r13
    jmp .dispatch

.op_not_literal:
    ; NOT_LITERAL ch — match any character EXCEPT ch
    mov rdi, r12
    call sre_string_len
    cmp r13, rax
    jge .op_failure
    mov r14d, [rbx]
    add rbx, 4
    mov rdi, r12
    mov rsi, r13
    call sre_getchar
    cmp eax, r14d
    je .op_failure
    inc r13
    jmp .dispatch

.op_literal_ignore:
    ; LITERAL_IGNORE ch — case-insensitive literal match
    mov rdi, r12
    call sre_string_len
    cmp r13, rax
    jge .op_failure
    mov r14d, [rbx]
    add rbx, 4
    mov rdi, r12
    mov rsi, r13
    call sre_getchar
    ; Compare lowercase versions
    push rax
    mov edi, eax
    call sre_ascii_tolower
    mov r14d, eax
    pop rax
    mov edi, [rbx - 4]        ; re-read expected
    call sre_ascii_tolower
    cmp r14d, eax
    jne .op_failure
    inc r13
    jmp .dispatch

.op_not_literal_ignore:
    ; NOT_LITERAL_IGNORE ch — case-insensitive not-literal
    mov rdi, r12
    call sre_string_len
    cmp r13, rax
    jge .op_failure
    mov r14d, [rbx]
    add rbx, 4
    mov rdi, r12
    mov rsi, r13
    call sre_getchar
    push rax
    mov edi, eax
    call sre_ascii_tolower
    mov r14d, eax
    pop rax
    mov edi, [rbx - 4]
    call sre_ascii_tolower
    cmp r14d, eax
    je .op_failure
    inc r13
    jmp .dispatch

.op_literal_uni_ignore:
    ; Same as literal_ignore but uses unicode tolower
    mov rdi, r12
    call sre_string_len
    cmp r13, rax
    jge .op_failure
    mov r14d, [rbx]
    add rbx, 4
    mov rdi, r12
    mov rsi, r13
    call sre_getchar
    push rax
    mov edi, eax
    call sre_unicode_tolower
    mov r14d, eax
    pop rax
    mov edi, [rbx - 4]
    call sre_unicode_tolower
    cmp r14d, eax
    jne .op_failure
    inc r13
    jmp .dispatch

.op_not_literal_uni_ignore:
    mov rdi, r12
    call sre_string_len
    cmp r13, rax
    jge .op_failure
    mov r14d, [rbx]
    add rbx, 4
    mov rdi, r12
    mov rsi, r13
    call sre_getchar
    push rax
    mov edi, eax
    call sre_unicode_tolower
    mov r14d, eax
    pop rax
    mov edi, [rbx - 4]
    call sre_unicode_tolower
    cmp r14d, eax
    je .op_failure
    inc r13
    jmp .dispatch

.op_in:
    ; IN skip_offset [set] — match char against character set
    mov rdi, r12
    call sre_string_len
    cmp r13, rax
    jge .op_failure
    mov r14d, [rbx]            ; skip offset (u32 count from after IN)
    add rbx, 4                 ; now at set data
    ; Get current char
    push rbx                   ; save set pointer
    mov rdi, r12
    mov rsi, r13
    call sre_getchar
    pop rdi                    ; set pointer
    mov esi, eax               ; character
    ; Check for NEGATE
    xor r14d, r14d             ; negate flag
    cmp dword [rdi], SRE_OP_NEGATE
    jne .in_no_negate
    mov r14d, 1
    add rdi, 4                 ; skip NEGATE opcode
.in_no_negate:
    push r14                   ; save negate flag
    call sre_charset
    pop r14
    ; Apply negate
    xor eax, r14d
    test eax, eax
    jz .op_failure
    ; Advance pc past the set
    ; rbx = skip_word_addr + 4 (set data start, preserved through calls)
    ; CPython: advance skip words from skip_word position
    mov eax, [rbx - 4]        ; re-read skip value
    lea rbx, [rbx + rax*4 - 4] ; skip_word_addr + skip*4
    inc r13
    jmp .dispatch

.op_in_ignore:
    ; Same as IN but case-insensitive
    mov rdi, r12
    call sre_string_len
    cmp r13, rax
    jge .op_failure
    mov r14d, [rbx]            ; skip offset
    add rbx, 4
    push rbx                   ; save set ptr
    mov rdi, r12
    mov rsi, r13
    call sre_getchar
    ; Lowercase the char for matching
    mov edi, eax
    call sre_ascii_tolower
    pop rdi                    ; set ptr
    mov esi, eax
    xor r14d, r14d
    cmp dword [rdi], SRE_OP_NEGATE
    jne .in_ign_no_neg
    mov r14d, 1
    add rdi, 4
.in_ign_no_neg:
    push r14
    call sre_charset
    pop r14
    xor eax, r14d
    test eax, eax
    jz .op_failure
    ; rbx = skip_word_addr + 4, same fix as .op_in
    mov eax, [rbx - 4]        ; re-read skip
    lea rbx, [rbx + rax*4 - 4] ; skip_word_addr + skip*4
    inc r13
    jmp .dispatch

.op_in_uni_ignore:
    ; Same as IN but case-insensitive using unicode tolower
    mov rdi, r12
    call sre_string_len
    cmp r13, rax
    jge .op_failure
    mov r14d, [rbx]            ; skip offset
    add rbx, 4
    push rbx                   ; save set ptr
    mov rdi, r12
    mov rsi, r13
    call sre_getchar
    ; Lowercase the char for matching (unicode)
    mov edi, eax
    call sre_unicode_tolower
    pop rdi                    ; set ptr
    mov esi, eax
    xor r14d, r14d
    cmp dword [rdi], SRE_OP_NEGATE
    jne .in_uni_ign_no_neg
    mov r14d, 1
    add rdi, 4
.in_uni_ign_no_neg:
    push r14
    call sre_charset
    pop r14
    xor eax, r14d
    test eax, eax
    jz .op_failure
    mov eax, [rbx - 4]        ; re-read skip
    lea rbx, [rbx + rax*4 - 4] ; skip_word_addr + skip*4
    inc r13
    jmp .dispatch

.op_info:
    ; INFO skip ... — skip past info block
    ; rbx points to skip word (already past INFO opcode)
    ; Need to advance skip*4 bytes from here: rbx + skip*4 = INFO + (1+skip)*4
    mov eax, [rbx]             ; skip (u32 words after INFO opcode)
    lea rbx, [rbx + rax*4]    ; advance past info block
    jmp .dispatch

.op_jump:
    ; JUMP offset — relative jump
    ; rbx points to offset word (already past JUMP opcode)
    ; CPython: ctx->pattern += ctx->pattern[0] (from offset word position)
    mov eax, [rbx]             ; offset
    lea rbx, [rbx + rax*4]    ; offset_addr + offset*4 = target
    jmp .dispatch

.op_mark:
    ; MARK mark_id — set mark at current position
    mov esi, [rbx]             ; mark_id
    add rbx, 4
    mov rdi, r12
    mov rdx, r13               ; current position
    push rbx
    call sre_state_set_mark
    pop rbx
    jmp .dispatch

.op_branch:
    ; BRANCH offset1 [pattern1] offset2 [pattern2] ... 0
    ; Try each branch in order
    mov r14, rbx               ; r14 = ptr to first offset

.branch_loop:
    ; r14 is a program counter of its own, and the guard at .dispatch bounds
    ; rbx only.  A crafted BRANCH offset walks this one off the end of the
    ; code array and the read below is where it lands -- the same hole the
    ; dispatch guard was written to close, in the one place that does not go
    ; through it.
    mov rax, [r12 + SRE_State.pattern]
    test rax, rax
    jz .branch_pc_ok
    mov rcx, [rax + SRE_PatternObject.code]
    mov rdx, [rax + SRE_PatternObject.code_len]
    shl rdx, 2
    add rdx, rcx                ; one past the end
    cmp r14, rcx
    jb .op_failure
    lea rax, [r14 + 4]          ; the offset word has to be inside as well
    cmp rax, rdx
    ja .op_failure
.branch_pc_ok:
    mov eax, [r14]             ; offset (0 = end of branches)
    test eax, eax
    jz .op_failure             ; no more branches

    ; Save state for backtracking
    push r13                   ; save position
    push r14                   ; save branch pointer
    ; Save marks
    mov rdi, r12
    call sre_save_marks
    push rax                   ; saved marks ptr

    ; Try this branch
    mov [r12 + SRE_State.str_pos], r13
    mov rdi, r12
    lea rsi, [r14 + 4]        ; pattern after offset
    mov edx, [rbp - SM_TOPLEVEL]   ; a continuation of THIS match, so it
                                   ; inherits whether this one is the top
    call sre_match

    test eax, eax
    jnz .branch_success

    ; Restore marks and try next branch
    pop rdi                    ; saved marks
    push rdi
    mov rsi, r12
    call sre_restore_marks
    pop rdi
    call ap_free               ; free saved marks

    pop r14                    ; restore branch ptr
    pop r13                    ; restore position

    ; Advance to next branch
    mov eax, [r14]
    lea r14, [r14 + rax*4]    ; next branch offset
    jmp .branch_loop

.branch_success:
    ; Clean up saved state
    pop rdi                    ; saved marks (already used by match)
    call ap_free
    pop r14
    pop r13
    mov r13, [r12 + SRE_State.str_pos]  ; update position from state
    mov eax, 1
    jmp .return

.op_category:
    ; CATEGORY code — match char against category
    mov rdi, r12
    call sre_string_len
    cmp r13, rax
    jge .op_failure
    mov r14d, [rbx]            ; category code
    add rbx, 4
    mov rdi, r12
    mov rsi, r13
    push rbx
    call sre_getchar
    mov edi, r14d
    mov esi, eax
    call sre_category
    pop rbx
    test eax, eax
    jz .op_failure
    inc r13
    jmp .dispatch

.op_charset:
.op_bigcharset:
    ; These should only appear inside IN sets, not at top level
    jmp .op_failure

.op_negate:
.op_range:
    ; These should only appear inside IN sets
    jmp .op_failure

.op_groupref:
    ; GROUPREF group — match same text as group
    mov eax, [rbx]             ; group id
    add rbx, 4
    ; Get group start and end marks
    mov ecx, eax
    shl ecx, 1                 ; mark_start = group * 2
    push rbx
    mov rdi, r12
    mov rsi, rcx
    call sre_state_get_mark
    mov r14, rax               ; group start pos
    cmp r14, -1
    je .groupref_fail
    mov rdi, r12
    lea rsi, [rcx + 1]        ; mark_end = group * 2 + 1
    call sre_state_get_mark
    mov r8, rax                ; group end pos
    cmp r8, -1
    je .groupref_fail

    ; Match characters from group_start..group_end at current pos
    mov rcx, r8
    sub rcx, r14               ; group length
    test rcx, rcx
    jz .groupref_done          ; empty group matches

    ; Check enough chars remain
    mov rdi, r12
    call sre_string_len
    sub rax, r13               ; remaining chars
    cmp rax, rcx
    jb .groupref_fail

    ; Compare char by char
    xor r9d, r9d               ; offset
.groupref_cmp:
    cmp r9, rcx
    jge .groupref_done
    mov rdi, r12
    lea rsi, [r14 + r9]       ; group char index
    push rcx
    push r9
    call sre_getchar
    mov r10d, eax              ; expected char
    pop r9
    pop rcx
    mov rdi, r12
    lea rsi, [r13 + r9]       ; current char index
    push rcx
    push r9
    push r10
    call sre_getchar
    pop r10
    pop r9
    pop rcx
    cmp eax, r10d
    jne .groupref_fail
    inc r9
    jmp .groupref_cmp

.groupref_done:
    pop rbx
    add r13, rcx               ; advance position
    jmp .dispatch
.groupref_fail:
    pop rbx
    jmp .op_failure

.op_groupref_exists:
    ; GROUPREF_EXISTS group jump_offset — conditional
    mov eax, [rbx]             ; group
    mov ecx, [rbx + 4]        ; jump offset (if group not matched)
    add rbx, 8
    ; Check if group is matched
    shl eax, 1
    push rbx
    push rcx
    mov rdi, r12
    mov esi, eax
    call sre_state_get_mark
    cmp rax, -1
    je .gre_not_matched
    ; Also check end mark
    pop rcx
    pop rbx
    push rbx
    push rcx
    mov rdi, r12
    lea esi, [eax + 1]
    call sre_state_get_mark
    cmp rax, -1
    je .gre_not_matched
    pop rcx
    pop rbx
    ; Group matched — continue with next instruction (true branch)
    jmp .dispatch
.gre_not_matched:
    pop rcx                    ; jump offset
    pop rbx
    ; rbx = group_id_addr + 8 (past both args)
    ; CPython: pattern += skip from group_id position
    lea rbx, [rbx + rcx*4 - 8] ; group_id_addr + skip*4
    jmp .dispatch

.op_subpattern:
    ; SUBPATTERN group_id dir ... — mark group boundaries
    ; Format: SUBPATTERN group_id 0 0 0 (4 args)
    mov eax, [rbx]             ; group_id
    add rbx, 12                ; skip group_id, 0, 0 (3 more u32s past group_id)
    ; The mark operations are handled by MARK opcodes that follow
    jmp .dispatch

.op_repeat_one:
    ; REPEAT_ONE skip min max [pattern] — greedy repeat with single-char body
    ; skip = u32 words from REPEAT_ONE to past the body
    ; min = minimum repeats
    ; max = maximum repeats (SRE_MAXREPEAT for unlimited)
    ;
    ; The counters are 64-bit and every comparison below is SIGNED.  They used
    ; to be 32-bit with the two directions disagreeing, and both halves were
    ; wrong:
    ;
    ;   MAXREPEAT is 0xFFFFFFFF, which as an int32 is -1.  `cmp r9d, r8d /
    ;   jge` therefore read 0 >= -1 as true and skipped the greedy loop
    ;   entirely, so EVERY unbounded quantifier -- *, +, {n,} -- matched its
    ;   minimum and stopped.  `.*` matched nothing.
    ;
    ;   The back-off then did `dec r9d` on a 32-bit counter and tested it with
    ;   an UNSIGNED jb, so 0 - 1 became 0xFFFFFFFF, which is below nothing.
    ;   The loop never terminated on the low side and walked the position
    ;   negative, one byte at a time, until it stepped off the front of the
    ;   mapped page.  That was the segfault on `.*x\Z`.
    ;
    ; Loading a u32 with a 32-bit move zero-extends, so max is 4294967295 as a
    ; signed 64-bit value -- positive, and larger than any real count.
    mov r14d, [rbx]            ; skip
    mov ecx, [rbx + 4]        ; min, zero-extended into rcx
    mov r8d, [rbx + 8]        ; max, likewise
    add rbx, 12                ; past skip/min/max, pointing at body pattern

    ; Save state
    push r13                   ; save start pos

    ; First, match minimum required repetitions
    mov r9, rcx                ; remaining minimum
    test r9, r9
    jz .ro_min_done

.ro_min_loop:
    ; Save and try body match.  rcx holds min and is caller-saved, so it goes
    ; on the stack with the rest: op_min_repeat_one already knew this and
    ; re-read min from memory afterwards; this one never did, and the stale
    ; register is half of the back-off bug above.
    mov [r12 + SRE_State.str_pos], r13
    push r9
    push r8
    push rcx
    push r14
    mov rdi, r12
    mov rsi, rbx               ; body pattern
    xor edx, edx               ; a sub-pattern: its SUCCESS is not the match
    call sre_match
    pop r14
    pop rcx
    pop r8
    pop r9
    test eax, eax
    jz .ro_min_fail
    mov r13, [r12 + SRE_State.str_pos]
    dec r9
    test r9, r9
    jnz .ro_min_loop
.ro_min_done:

    ; Now greedily match up to max
    ; Count successful body matches
    mov r9, rcx                ; current count = min
    cmp r9, r8
    jge .ro_greedy_done

.ro_greedy_loop:
    push r13                   ; save pos before body try
    mov [r12 + SRE_State.str_pos], r13
    push r9
    push r8
    push rcx
    push r14
    mov rdi, r12
    mov rsi, rbx               ; body pattern
    xor edx, edx               ; a sub-pattern: its SUCCESS is not the match
    call sre_match
    pop r14
    pop rcx
    pop r8
    pop r9
    test eax, eax
    jz .ro_greedy_body_fail
    mov r13, [r12 + SRE_State.str_pos]
    add rsp, 8                 ; discard saved pos (body succeeded)
    inc r9
    cmp r9, r8
    jl .ro_greedy_loop
    jmp .ro_greedy_done

.ro_greedy_body_fail:
    pop r13                    ; restore pos (body failed)
.ro_greedy_done:
    ; Now try tail (pattern after REPEAT_ONE body)
    ; Tail starts at skip_word_addr + skip*4
    ; rbx = skip_word_addr + 12 (past skip/min/max)
    ; CPython: ctx->pattern += ctx->pattern[0] from skip_word_addr
    ; rcx holds min and must survive: the back-off below compares against it.
    ; Computing the tail address through rcx destroyed it, so the very first
    ; back-off compared the count against a pattern ADDRESS and gave up --
    ; which is why the greedy match worked and no shorter one was ever found.
    lea rdx, [rbx - 12]       ; skip_word_addr
    mov eax, r14d              ; skip
    lea r14, [rdx + rax*4]    ; tail pattern

    ; Try tail from current position, back off on failure (greedy backtracking)
.ro_tail_loop:
    mov [r12 + SRE_State.str_pos], r13
    push r13
    push r9
    push rcx
    push rcx                   ; twice: rsp must stay 16-byte aligned
    mov rdi, r12
    mov rsi, r14               ; tail pattern
    mov edx, [rbp - SM_TOPLEVEL]   ; a continuation of THIS match, so it
                                   ; inherits whether this one is the top
    call sre_match
    pop rcx
    pop rcx
    pop r9
    test eax, eax
    jnz .ro_tail_success

    pop r13                    ; restore pos
    ; Back off one body match.  64-bit and SIGNED: min is never negative, so
    ; the count reaching -1 is what ends the loop.
    dec r9
    cmp r9, rcx
    jl .ro_fail                ; below minimum, fail
    ; The body is a single character, so undoing one match is one position.
    dec r13
    jmp .ro_tail_loop

.ro_tail_success:
    pop r13                    ; discard saved pos
    mov r13, [r12 + SRE_State.str_pos]
    add rsp, 8                 ; discard initial saved pos
    mov eax, 1
    jmp .return

.ro_min_fail:
    pop r13                    ; restore start pos
    jmp .op_failure

.ro_fail:
    pop r13                    ; restore start pos
    jmp .op_failure

.op_min_repeat_one:
    ; MIN_REPEAT_ONE skip min max [pattern] — non-greedy repeat
    mov r14d, [rbx]            ; skip
    mov ecx, [rbx + 4]        ; min
    mov r8d, [rbx + 8]        ; max
    add rbx, 12

    push r13                   ; save start pos

    ; Match minimum
    mov r9d, ecx
    test r9d, r9d
    jz .mro_min_done
.mro_min_loop:
    mov [r12 + SRE_State.str_pos], r13
    push r9
    push r8
    push r14
    push rcx
    mov rdi, r12
    mov rsi, rbx
    xor edx, edx               ; a sub-pattern: its SUCCESS is not the match
    call sre_match
    pop rcx
    pop r14
    pop r8
    pop r9
    test eax, eax
    jz .mro_fail
    mov r13, [r12 + SRE_State.str_pos]
    dec r9d
    test r9d, r9d
    jnz .mro_min_loop
.mro_min_done:

    ; Calculate tail
    ; rbx = skip_word_addr + 12
    mov eax, r14d
    lea r14, [rbx - 12]          ; skip_word_addr
    lea r14, [r14 + rax*4]       ; skip_word_addr + skip*4

    ; Non-greedy: try tail first, then extend
    mov r9d, [rbx - 8]        ; re-read min (ecx may be clobbered)
.mro_tail_loop:
    mov [r12 + SRE_State.str_pos], r13
    push r13
    push r9
    push r14
    mov rdi, r12
    mov rsi, r14
    mov edx, [rbp - SM_TOPLEVEL]   ; a continuation of THIS match, so it
                                   ; inherits whether this one is the top
    call sre_match
    pop r14
    pop r9
    test eax, eax
    jnz .mro_success

    pop r13
    ; Try one more body match
    ; 64-bit and signed: MAXREPEAT is 0xFFFFFFFF, which as an int32 is -1,
    ; so a 32-bit `jge` here read "count >= max" as true at once and the
    ; loop never ran.  See op_repeat_one for the whole story.
    mov rdx, [rbx - 4]
    mov edx, edx                ; zero-extend the u32 max
    cmp r9, rdx
    jge .mro_fail
    mov [r12 + SRE_State.str_pos], r13
    push r9
    push r14
    mov rdi, r12
    mov rsi, rbx               ; body pattern
    xor edx, edx               ; a sub-pattern: its SUCCESS is not the match
    call sre_match
    pop r14
    pop r9
    test eax, eax
    jz .mro_fail
    mov r13, [r12 + SRE_State.str_pos]
    inc r9d
    jmp .mro_tail_loop

.mro_success:
    pop r13
    mov r13, [r12 + SRE_State.str_pos]
    add rsp, 8                 ; discard initial saved pos
    mov eax, 1
    jmp .return

.mro_fail:
    pop r13
    jmp .op_failure

.op_repeat:
    ; REPEAT skip min max — general repeat (body may be multi-char)
    ; Uses REPEAT_CTX for backtracking with MAX_UNTIL/MIN_UNTIL
    mov eax, [rbx]             ; skip
    mov ecx, [rbx + 4]        ; min
    mov r8d, [rbx + 8]        ; max
    add rbx, 12

    ; Create RepeatContext on stack
    ; We'll use a dynamically allocated one for simplicity
    push rbx
    push rcx
    push r8
    mov edi, SRE_RepeatContext_size
    call ap_malloc
    pop r8
    pop rcx
    pop rbx
    ; count starts at -1 and last_pos at "nowhere", as CPython's
    ; sre_lib.h does.  MAX_UNTIL increments before reading, so -1 makes the
    ; first entry see 0; starting at 0 made it see 1, and `(ab)+` with min 1
    ; then decided it had already matched once and went straight to the tail.
    ; And last_pos = r13 made the zero-width guard fire on the FIRST
    ; iteration, because the body had not moved yet by definition -- so the
    ; body was never attempted at all and every multi-character repeat
    ; matched zero times.
    mov qword [rax + SRE_RepeatContext.count], -1
    mov [rax + SRE_RepeatContext.pattern], rbx  ; points to body (after skip/min/max)
    mov [rax + SRE_RepeatContext.prev], r15
    mov qword [rax + SRE_RepeatContext.last_pos], -1

    ; Push onto repeat context chain
    mov r15, rax
    mov [r12 + SRE_State.repeat_ctx], r15

    ; Pattern after REPEAT = skip_word_addr + skip*4
    ; rbx = skip_word_addr + 12 (past skip/min/max)
    ; CPython: ctx->pattern += ctx->pattern[0] from skip_word_addr
    mov eax, [rbx - 12]
    lea rbx, [rbx - 12 + rax*4]

    ; Continue dispatch — MAX_UNTIL or MIN_UNTIL will handle the body
    jmp .dispatch

.op_max_until:
    ; MAX_UNTIL -- greedy repeat body iteration.
    ;
    ; The count discipline is CPython's, and it has to be exact: rep->count is
    ; written only by a branch that is about to attempt the body, and put back
    ; before control reaches the tail.  Incrementing it on the way in and
    ; decrementing it on every failure path instead left it one too LOW when a
    ; greedy body attempt failed and the tail then failed as well -- two
    ; decrements for one increment -- so the enclosing repeat iterated again
    ; from a count it had already spent.  `(a*)+` against 'a1' recursed until
    ; the depth limit rather than answering None; `(a*)*` did not, because
    ; with min == 0 the first branch below is never taken.
    test r15, r15
    jz .op_failure

    mov rax, [r15 + SRE_RepeatContext.count]
    inc rax
    mov [rbp - SM_COUNT], rax          ; ctx->count; rep->count stays as it was

    ; min at pattern - 8, max at pattern - 4
    mov rcx, [r15 + SRE_RepeatContext.pattern]
    mov r8d, [rcx - 8]
    mov r9d, [rcx - 4]

    cmp rax, r8
    jb .mu_try_body

    ; Enough matches.  Try for one more only when the repeat is not full and
    ; the last iteration was not empty -- the second is the zero-width guard,
    ; and it is a plain compare against the repeat's own last_pos, not against
    ; a saved copy.
    cmp r9d, SRE_MAXREPEAT
    je .mu_greedy_ok
    cmp rax, r9
    jae .mu_try_tail
.mu_greedy_ok:
    cmp r13, [r15 + SRE_RepeatContext.last_pos]
    je .mu_try_tail

    mov [r15 + SRE_RepeatContext.count], rax
    ; last_pos is saved across the attempt and put back after it, whether it
    ; succeeds or fails: CPython's DATA_PUSH/DATA_POP pair.
    mov rdx, [r15 + SRE_RepeatContext.last_pos]
    mov [rbp - SM_LASTPOS], rdx
    mov [r15 + SRE_RepeatContext.last_pos], r13

    push r13
    mov rdi, r12
    call sre_save_marks
    push rax

    mov [r12 + SRE_State.str_pos], r13
    mov rdi, r12
    mov rsi, [r15 + SRE_RepeatContext.pattern]
    mov edx, [rbp - SM_TOPLEVEL]   ; the body's continuation IS the tail --
                                   ; MAX_UNTIL follows it -- so the SUCCESS it
                                   ; eventually reaches is the pattern's own
    call sre_match
    test eax, eax
    jnz .mu_body_success

    ; Body failed: marks, last_pos, count and position all go back.
    pop rdi
    push rdi
    mov rsi, r12
    call sre_restore_marks
    pop rdi
    call ap_free
    pop r13
    mov rdx, [rbp - SM_LASTPOS]
    mov [r15 + SRE_RepeatContext.last_pos], rdx
    mov rax, [rbp - SM_COUNT]
    dec rax
    mov [r15 + SRE_RepeatContext.count], rax
    jmp .mu_try_tail

.mu_body_success:
    ; CPython's DATA_POP puts last_ptr back here too, and can: its repeat
    ; context is a stack frame.  Ours is heap-allocated and .mu_tail_success
    ; frees it, so on the way out through a successful body the context this
    ; r15 names may already be gone -- writing to it is a use-after-free that
    ; valgrind sees immediately.  Nothing reads it after a success anyway.
    pop rdi                    ; free saved marks
    call ap_free
    pop r13
    mov r13, [r12 + SRE_State.str_pos]
    mov eax, 1
    jmp .return

.mu_try_body:
    ; count < min: the body is not optional here.
    mov [r15 + SRE_RepeatContext.count], rax
    mov [r12 + SRE_State.str_pos], r13
    mov rdi, r12
    mov rsi, [r15 + SRE_RepeatContext.pattern]
    mov edx, [rbp - SM_TOPLEVEL]
    call sre_match
    test eax, eax
    jz .mu_body_required_fail
    mov r13, [r12 + SRE_State.str_pos]
    mov eax, 1
    jmp .return

.mu_body_required_fail:
    mov rax, [rbp - SM_COUNT]
    dec rax
    mov [r15 + SRE_RepeatContext.count], rax
    jmp .op_failure

.mu_try_tail:
    ; Pop the repeat context and try the tail.  rep->count is already what it
    ; was on entry, whichever way control reached here.
    mov rax, [r15 + SRE_RepeatContext.prev]
    push r15                   ; save for potential restore
    mov r15, rax
    mov [r12 + SRE_State.repeat_ctx], r15

    mov [r12 + SRE_State.str_pos], r13
    mov rdi, r12
    mov rsi, rbx               ; tail = code after MAX_UNTIL
    mov edx, [rbp - SM_TOPLEVEL]   ; a continuation of THIS match, so it
                                   ; inherits whether this one is the top
    call sre_match
    test eax, eax
    jnz .mu_tail_success

    ; Restore repeat context
    pop r15
    mov [r12 + SRE_State.repeat_ctx], r15
    jmp .op_failure

.mu_tail_success:
    ; Free repeat context
    pop rdi                    ; old r15
    call ap_free
    mov r13, [r12 + SRE_State.str_pos]
    mov eax, 1
    jmp .return

.op_min_until:
    ; MIN_UNTIL -- non-greedy repeat body iteration.
    ;
    ; sre_lib.h's order, which is not the mirror image of MAX_UNTIL's: the
    ; tail is tried FIRST, and only when it fails are the bound and the
    ; zero-width guard consulted and the body attempted.  Ours applied the
    ; zero-width guard to the count < min path as well, where CPython does
    ; not, and kept rep->count with an increment on the way in and a
    ; decrement on each way out -- the same shape that made MAX_UNTIL loop.
    test r15, r15
    jz .op_failure

    mov rax, [r15 + SRE_RepeatContext.count]
    inc rax
    mov [rbp - SM_COUNT], rax       ; ctx->count; rep->count stays as it was

    mov rcx, [r15 + SRE_RepeatContext.pattern]
    mov r8d, [rcx - 8]        ; min
    cmp rax, r8
    jb .miu_required_body

    ; See if the tail matches.
    push r13
    mov rax, [r15 + SRE_RepeatContext.prev]
    push r15
    mov r15, rax
    mov [r12 + SRE_State.repeat_ctx], r15

    mov [r12 + SRE_State.str_pos], r13
    mov rdi, r12
    mov rsi, rbx
    mov edx, [rbp - SM_TOPLEVEL]   ; a continuation of THIS match, so it
                                   ; inherits whether this one is the top
    call sre_match
    test eax, eax
    jnz .miu_tail_success

    ; Restore the repeat context and the position.
    pop r15
    mov [r12 + SRE_State.repeat_ctx], r15
    pop r13

    ; Out of iterations, or the last one matched empty: no body attempt.
    mov rax, [rbp - SM_COUNT]
    mov rcx, [r15 + SRE_RepeatContext.pattern]
    mov r9d, [rcx - 4]        ; max
    cmp r9d, SRE_MAXREPEAT
    je .miu_bound_ok
    cmp rax, r9
    jae .op_failure
.miu_bound_ok:
    cmp r13, [r15 + SRE_RepeatContext.last_pos]
    je .op_failure

    ; One more iteration of the body, with last_pos AND the group marks saved
    ; across it -- CPython's MIN_UNTIL_3 does LASTMARK_SAVE/LASTMARK_RESTORE,
    ; and MAX_UNTIL here already does.  Without the marks a failed lazy
    ; iteration left half-written ones behind, so a group could end up with
    ; start > end: `(a)(a?)+?a+?` on 'aab' reported span(2) == (2, 1), and
    ; group(2) then asked for a slice of length -1.
    mov [r15 + SRE_RepeatContext.count], rax
    mov rdx, [r15 + SRE_RepeatContext.last_pos]
    mov [rbp - SM_LASTPOS], rdx
    mov [r15 + SRE_RepeatContext.last_pos], r13

    mov rdi, r12
    call sre_save_marks
    push rax
    sub rsp, 8

    mov [r12 + SRE_State.str_pos], r13
    mov rdi, r12
    mov rsi, [r15 + SRE_RepeatContext.pattern]
    mov edx, [rbp - SM_TOPLEVEL]   ; as in MAX_UNTIL: the body's continuation
                                   ; is MIN_UNTIL and so the tail, which makes
                                   ; the SUCCESS it reaches the pattern's own
    call sre_match
    test eax, eax
    jnz .miu_body_matched       ; see .mu_body_success: no write on this path
    add rsp, 8
    pop rdi
    push rdi
    mov rsi, r12
    call sre_restore_marks
    pop rdi
    call ap_free
    mov rdx, [rbp - SM_LASTPOS]
    mov [r15 + SRE_RepeatContext.last_pos], rdx
    mov rax, [rbp - SM_COUNT]
    dec rax
    mov [r15 + SRE_RepeatContext.count], rax
    jmp .op_failure
.miu_body_matched:
    add rsp, 8
    pop rdi
    call ap_free
    jmp .miu_body_ok

.miu_required_body:
    ; count < min: the body is not optional here, and no guard applies.
    mov [r15 + SRE_RepeatContext.count], rax
    mov [r12 + SRE_State.str_pos], r13
    mov rdi, r12
    mov rsi, [r15 + SRE_RepeatContext.pattern]
    mov edx, [rbp - SM_TOPLEVEL]
    call sre_match
    test eax, eax
    jnz .miu_body_ok
    mov rax, [rbp - SM_COUNT]
    dec rax
    mov [r15 + SRE_RepeatContext.count], rax
    jmp .op_failure

.miu_body_ok:
    mov r13, [r12 + SRE_State.str_pos]
    mov eax, 1
    jmp .return

.miu_tail_success:
    pop rdi                    ; old r15
    call ap_free
    pop r13
    mov r13, [r12 + SRE_State.str_pos]
    mov eax, 1
    jmp .return

.op_assert:
    ; ASSERT skip back [pattern] — lookahead and lookbehind
    ;
    ; TWO operand words, not three.  CPython's compiler emits <skip> <back>
    ; and nothing else (_compiler.py's ASSERT_CODES arm), where back is how
    ; far to step the position back before running the body: 0 means
    ; lookahead, a positive count means lookbehind.  There is no direction
    ; word and there is no -1.
    ;
    ; Reading a third word took the body's FIRST OPCODE as "width" and left
    ; the body pointer one word too far, so every positive lookaround
    ; dispatched into the middle of an instruction and failed; and the
    ; `cmp ecx, -1` test could never be true, so lookbehind ran as lookahead
    ; with no step back at all.
    mov r8d, [rbx + 4]        ; back
    add rbx, 8                 ; the body

    ; Stepping back further than the string is a failure, not a wrap.
    cmp r13, r8
    jb .op_failure
    push r13
    push rbx
    sub r13, r8
    mov [r12 + SRE_State.str_pos], r13
    mov rdi, r12
    mov rsi, rbx               ; assert body pattern
    xor edx, edx               ; a sub-pattern: its SUCCESS is not the match
    call sre_match
    pop rbx
    pop r13
    test eax, eax
    jz .op_failure
    ; An assertion consumes nothing: the position is whatever it was, and the
    ; pattern advances by skip from the skip word.
    mov [r12 + SRE_State.str_pos], r13
    mov eax, [rbx - 8]        ; skip
    lea rbx, [rbx - 8 + rax*4]
    jmp .dispatch

.op_assert_not:
    ; ASSERT_NOT skip back [pattern] — the negative forms.  Two operand words,
    ; exactly as ASSERT above; the same three-word decode was here, and its
    ; accidental "the body always fails" behaviour made every negative
    ; lookaround succeed vacuously.
    mov r8d, [rbx + 4]        ; back
    add rbx, 8                 ; the body

    ; Not enough string to look behind means the pattern cannot be there,
    ; so the negative assertion passes.
    cmp r13, r8
    jb .assert_not_pass
    push r13
    push rbx
    sub r13, r8
    mov [r12 + SRE_State.str_pos], r13
    mov rdi, r12
    mov rsi, rbx
    xor edx, edx               ; a sub-pattern: its SUCCESS is not the match
    call sre_match
    pop rbx
    pop r13
    test eax, eax
    jnz .op_failure            ; it matched — the negative assertion fails

.assert_not_pass:
    mov [r12 + SRE_State.str_pos], r13
    mov eax, [rbx - 8]        ; skip
    lea rbx, [rbx - 8 + rax*4]
    jmp .dispatch

.op_atomic_group:
    ; ATOMIC_GROUP skip [pattern] — match pattern atomically (no backtracking)
    mov r14d, [rbx]            ; skip
    add rbx, 4
    push r13
    mov [r12 + SRE_State.str_pos], r13
    mov rdi, r12
    mov rsi, rbx               ; body pattern
    xor edx, edx               ; a sub-pattern: its SUCCESS is not the match
    call sre_match
    pop r14                    ; saved pos (discard on success, restore on failure)
    test eax, eax
    jz .atomic_fail
    mov r13, [r12 + SRE_State.str_pos]
    ; Advance past body
    ; rbx = skip_word_addr + 4 (body start)
    ; CPython: ctx->pattern += ctx->pattern[0] from skip_word_addr
    mov eax, [rbx - 4]        ; skip
    lea rbx, [rbx - 4 + rax*4]
    jmp .dispatch
.atomic_fail:
    mov r13, r14               ; restore position
    jmp .op_failure

.op_possessive_repeat:
    ; POSSESSIVE_REPEAT skip min max body SUCCESS tail -- CPython's
    ; SRE_OP_POSSESSIVE_REPEAT.  Each iteration is a sub-match of the body,
    ; whose SUCCESS ends that sub-match only; once the loop stops nothing
    ; backtracks into it.  An iteration that fails must leave no trace: its
    ; marks are put back (LASTMARK_SAVE/MARK_PUSH, MARK_POP/LASTMARK_RESTORE),
    ; or a group the failed attempt opened reads as matched.  And the tail is
    ; one word PAST skip: skip lands on the body's SUCCESS, and dispatching
    ; that ended the whole match right after the body.
    mov eax, [rbx]
    mov [rbp - SM_PR_SKIP], rax
    mov eax, [rbx + 4]
    mov [rbp - SM_PR_MIN], rax
    mov eax, [rbx + 8]
    mov [rbp - SM_PR_MAX], rax
    mov [rbp - SM_PR_START], r13
    mov qword [rbp - SM_PR_COUNT], 0
    add rbx, 12                ; body pattern

    ; The minimum: every one of these has to match.
.pr_min_loop:
    mov rax, [rbp - SM_PR_COUNT]
    cmp rax, [rbp - SM_PR_MIN]
    jge .pr_min_done
    mov [r12 + SRE_State.str_pos], r13
    mov rdi, r12
    mov rsi, rbx
    xor edx, edx               ; a sub-pattern: its SUCCESS is not the match
    call sre_match
    test eax, eax
    jz .pr_fail
    mov r13, [r12 + SRE_State.str_pos]
    inc qword [rbp - SM_PR_COUNT]
    jmp .pr_min_loop
.pr_min_done:

    ; Then greedily up to max, stopping at the first failure or at the first
    ; iteration that matched empty (every later one would too).
.pr_greedy_loop:
    ; 64-bit and signed: MAXREPEAT is 0xFFFFFFFF, which as an int32 is -1,
    ; so a 32-bit `jge` here read "count >= max" as true at once and the
    ; loop never ran.  See op_repeat_one for the whole story.
    mov rax, [rbp - SM_PR_COUNT]
    cmp rax, [rbp - SM_PR_MAX]
    jge .pr_greedy_done
    mov rdi, r12
    call sre_save_marks
    mov [rbp - SM_PR_MARKS], rax
    mov [r12 + SRE_State.str_pos], r13
    mov rdi, r12
    mov rsi, rbx
    xor edx, edx               ; a sub-pattern: its SUCCESS is not the match
    call sre_match
    test eax, eax
    jz .pr_greedy_stop
    mov rdi, [rbp - SM_PR_MARKS]   ; MARK_POP_DISCARD: keep the new marks
    call ap_free
    inc qword [rbp - SM_PR_COUNT]
    mov rax, [r12 + SRE_State.str_pos]
    cmp rax, r13
    mov r13, rax
    je .pr_greedy_done         ; zero-width: no further progress possible
    jmp .pr_greedy_loop
.pr_greedy_stop:
    mov rdi, [rbp - SM_PR_MARKS]   ; MARK_POP + LASTMARK_RESTORE
    mov rsi, r12
    call sre_restore_marks
    mov rdi, [rbp - SM_PR_MARKS]
    call ap_free
.pr_greedy_done:
    mov [r12 + SRE_State.str_pos], r13
    ; CPython: pattern += pattern[0] + 1, from the skip word -- past SUCCESS.
    mov rax, [rbp - SM_PR_SKIP]
    lea rbx, [rbx - 12 + rax*4 + 4]
    jmp .dispatch

.pr_fail:
    mov r13, [rbp - SM_PR_START]
    mov [r12 + SRE_State.str_pos], r13
    jmp .op_failure

.op_possessive_repeat_one:
    ; POSSESSIVE_REPEAT_ONE skip min max item SUCCESS tail.  The item is one
    ; character wide and holds no marks, so a failed attempt has nothing to
    ; undo; skip lands on the tail itself.  Kept in the same frame slots as
    ; POSSESSIVE_REPEAT -- the push-based version called sre_match with rsp
    ; 8 off in its minimum loop.
    mov eax, [rbx]
    mov [rbp - SM_PR_SKIP], rax
    mov eax, [rbx + 4]
    mov [rbp - SM_PR_MIN], rax
    mov eax, [rbx + 8]
    mov [rbp - SM_PR_MAX], rax
    mov [rbp - SM_PR_START], r13
    mov qword [rbp - SM_PR_COUNT], 0
    add rbx, 12                ; the item

.pro_loop:
    ; 64-bit and signed: MAXREPEAT is 0xFFFFFFFF, which as an int32 is -1.
    ; See op_repeat_one for the whole story.
    mov rax, [rbp - SM_PR_COUNT]
    cmp rax, [rbp - SM_PR_MAX]
    jge .pro_done
    mov [r12 + SRE_State.str_pos], r13
    mov rdi, r12
    mov rsi, rbx
    xor edx, edx               ; a sub-pattern: its SUCCESS is not the match
    call sre_match
    test eax, eax
    jz .pro_done
    mov r13, [r12 + SRE_State.str_pos]
    inc qword [rbp - SM_PR_COUNT]
    jmp .pro_loop
.pro_done:
    mov rax, [rbp - SM_PR_COUNT]
    cmp rax, [rbp - SM_PR_MIN]
    jl .pro_fail
    mov [r12 + SRE_State.str_pos], r13
    mov rax, [rbp - SM_PR_SKIP]
    lea rbx, [rbx - 12 + rax*4]    ; skip_word_addr + skip*4: the tail
    jmp .dispatch

.pro_fail:
    mov r13, [rbp - SM_PR_START]
    mov [r12 + SRE_State.str_pos], r13
    jmp .op_failure

.op_groupref_ignore:
    ; GROUPREF_IGNORE group — case-insensitive group reference
    mov eax, [rbx]
    add rbx, 4
    mov ecx, eax
    shl ecx, 1
    push rbx
    mov rdi, r12
    mov rsi, rcx
    call sre_state_get_mark
    mov r14, rax
    cmp r14, -1
    je .gri_fail
    mov rdi, r12
    lea rsi, [rcx + 1]
    call sre_state_get_mark
    mov r8, rax
    cmp r8, -1
    je .gri_fail

    mov rcx, r8
    sub rcx, r14
    test rcx, rcx
    jz .gri_done

    mov rdi, r12
    call sre_string_len
    sub rax, r13
    cmp rax, rcx
    jb .gri_fail

    xor r9d, r9d
.gri_cmp:
    cmp r9, rcx
    jge .gri_done
    push rcx
    push r9
    mov rdi, r12
    lea rsi, [r14 + r9]
    call sre_getchar
    mov edi, eax
    call sre_ascii_tolower
    mov r10d, eax
    pop r9
    push r9
    mov rdi, r12
    lea rsi, [r13 + r9]
    call sre_getchar
    mov edi, eax
    call sre_ascii_tolower
    pop r9
    pop rcx
    cmp eax, r10d
    jne .gri_fail
    inc r9
    jmp .gri_cmp

.gri_done:
    pop rbx
    add r13, rcx
    jmp .dispatch
.gri_fail:
    pop rbx
    jmp .op_failure

.op_groupref_uni_ignore:
    ; GROUPREF_UNI_IGNORE group — case-insensitive group ref (unicode)
    mov eax, [rbx]
    add rbx, 4
    mov ecx, eax
    shl ecx, 1
    push rbx
    mov rdi, r12
    mov rsi, rcx
    call sre_state_get_mark
    mov r14, rax
    cmp r14, -1
    je .grui_fail
    mov rdi, r12
    lea rsi, [rcx + 1]
    call sre_state_get_mark
    mov r8, rax
    cmp r8, -1
    je .grui_fail

    mov rcx, r8
    sub rcx, r14
    test rcx, rcx
    jz .grui_done

    mov rdi, r12
    call sre_string_len
    sub rax, r13
    cmp rax, rcx
    jb .grui_fail

    xor r9d, r9d
.grui_cmp:
    cmp r9, rcx
    jge .grui_done
    push rcx
    push r9
    mov rdi, r12
    lea rsi, [r14 + r9]
    call sre_getchar
    mov edi, eax
    call sre_unicode_tolower
    mov r10d, eax
    pop r9
    push r9
    mov rdi, r12
    lea rsi, [r13 + r9]
    call sre_getchar
    mov edi, eax
    call sre_unicode_tolower
    pop r9
    pop rcx
    cmp eax, r10d
    jne .grui_fail
    inc r9
    jmp .grui_cmp

.grui_done:
    pop rbx
    add r13, rcx
    jmp .dispatch
.grui_fail:
    pop rbx
    jmp .op_failure

.return:
    ; On failure, free any RepeatContexts allocated during this invocation
    test eax, eax
    jnz .return_ok
    ; Walk r15 chain and free until we reach the initial r15 (saved on stack)
.free_repeat_loop:
    cmp r15, [rsp]             ; compare with saved initial r15
    je .return_cleanup_done
    test r15, r15
    jz .return_cleanup_done    ; safety: NULL chain end
    mov rdi, r15
    mov r15, [r15 + SRE_RepeatContext.prev]
    push rax
    call ap_free
    pop rax
    jmp .free_repeat_loop
.return_cleanup_done:
    ; Restore state.repeat_ctx to initial value
    mov [r12 + SRE_State.repeat_ctx], r15
.return_ok:
    dec dword [r12 + SRE_State.match_depth]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.recursion_error:
    ; Raise RuntimeError for recursion overflow
    lea rdi, [rel exc_RuntimeError_type]
    lea rsi, [rel sre_recursion_err_msg]
    call raise_exception
    mov eax, SRE_MATCH_ERROR
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC sre_match

;; ============================================================================
;; sre_save_marks(SRE_State* state) -> void*
;; Save marks snapshot for backtracking. Returns malloc'd buffer.
;; ============================================================================
DEF_FUNC sre_save_marks, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi               ; state

    mov rcx, [rbx + SRE_State.marks_size]
    test rcx, rcx
    jz .save_empty

    lea rdi, [rcx*8 + 24]     ; marks data + lastmark + lastindex + marks_size
    call ap_malloc
    mov r8, rax

    ; Copy header: marks_size, lastmark, lastindex
    mov rcx, [rbx + SRE_State.marks_size]
    mov [r8], rcx
    mov rcx, [rbx + SRE_State.lastmark]
    mov [r8 + 8], rcx
    mov rcx, [rbx + SRE_State.lastindex]
    mov [r8 + 16], rcx

    ; Copy marks data
    mov rdi, r8
    add rdi, 24
    mov rsi, [rbx + SRE_State.marks]
    mov rdx, [rbx + SRE_State.marks_size]
    shl rdx, 3
    call ap_memcpy

    mov rax, r8
    pop rbx
    leave
    ret

.save_empty:
    mov edi, 24
    call ap_malloc
    mov qword [rax], 0
    mov qword [rax + 8], -1
    mov qword [rax + 16], -1
    pop rbx
    leave
    ret
END_FUNC sre_save_marks

;; ============================================================================
;; sre_restore_marks(void* saved, SRE_State* state)
;; Restore marks from snapshot.
;; ============================================================================
DEF_FUNC sre_restore_marks
    push rbx
    push r12
    mov rbx, rsi               ; state
    mov r12, rdi               ; saved data

    ; Restore header
    mov rcx, [r12]             ; marks_size
    mov [rbx + SRE_State.marks_size], rcx
    mov rcx, [r12 + 8]        ; lastmark
    mov [rbx + SRE_State.lastmark], rcx
    mov rcx, [r12 + 16]       ; lastindex
    mov [rbx + SRE_State.lastindex], rcx

    ; Restore marks data
    mov rcx, [r12]
    test rcx, rcx
    jz .restore_done

    ; Bounds check: grow marks array if saved size > capacity
    cmp rcx, [rbx + SRE_State.marks_count]
    jbe .restore_fits
    ; Grow: realloc to saved marks_size
    push rcx
    mov [rbx + SRE_State.marks_count], rcx
    shl rcx, 3                ; bytes
    mov rsi, rcx               ; new size
    mov rdi, [rbx + SRE_State.marks]
    call ap_realloc
    mov [rbx + SRE_State.marks], rax
    pop rcx

.restore_fits:
    mov rdi, [rbx + SRE_State.marks]
    lea rsi, [r12 + 24]
    mov rdx, rcx
    shl rdx, 3
    push rcx
    push rcx                    ; a pair, so the call stays 16-byte aligned
    call ap_memcpy
    pop rcx
    pop rcx

.restore_done:
    ; Above the restored size sit the marks the abandoned branch wrote.  They
    ; were harmless while marks_size gated every read; now that the array
    ; itself carries the sentinel, a later mark can raise marks_size back over
    ; them and they would read as matches.
    mov rax, [rbx + SRE_State.marks]
    test rax, rax
    jz .restore_out
    mov rdx, [rbx + SRE_State.marks_count]
.restore_clear:
    cmp rcx, rdx
    jge .restore_out
    mov qword [rax + rcx*8], -1
    inc rcx
    jmp .restore_clear
.restore_out:
    pop r12
    pop rbx
    leave
    ret
END_FUNC sre_restore_marks

;; ============================================================================
;; sre_search(SRE_State* state) -> 0/1
;; Linear scan: try sre_match at each position from pos to endpos.
;; ============================================================================
DEF_FUNC sre_search, 40
    push rbx
    push r12
    push r13

    mov r12, rdi               ; state
    mov r13, [rdi + SRE_State.str_pos]  ; starting pos
    mov [r12 + SRE_State.search_origin], r13

    ; Get string length
    mov rdi, r12
    call sre_string_len
    mov rbx, rax               ; rbx = string length (endpos)

.search_loop:
    cmp r13, rbx
    ja .search_fail

    ; Reset marks for each attempt
    mov rdi, r12
    call sre_state_reset_marks
    mov [r12 + SRE_State.str_pos], r13
    mov [r12 + SRE_State.str_start], r13

    ; Try match at current position
    mov rdi, r12
    mov rsi, [r12 + SRE_State.pattern]
    mov rsi, [rsi + SRE_PatternObject.code]
    mov edx, 1                 ; toplevel: this SUCCESS ends the pattern
    call sre_match
    test eax, eax
    jnz .search_found

    inc r13
    jmp .search_loop

.search_found:
    mov eax, 1
    pop r13
    pop r12
    pop rbx
    leave
    ret

.search_fail:
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC sre_search


;; ============================================================================
;; sre_utf8_codepoint_to_byte(char* str, i64 byte_len, i64 target_cp_idx,
;;                             i64 start_byte, i64 start_cp_idx) -> i64 byte_offset
;; Walk UTF-8 bytes from (start_byte, start_cp_idx) until codepoint count
;; reaches target_cp_idx. Returns the byte offset.
;; rdi = string start, rsi = total byte length, rdx = target codepoint index,
;; rcx = starting byte offset, r8 = starting codepoint index
;; Returns: rax = byte offset at target codepoint
;; ============================================================================
DEF_FUNC_BARE sre_utf8_codepoint_to_byte
    mov rax, rcx               ; byte offset
    mov r9, r8                 ; codepoint count
.u8walk:
    cmp r9, rdx
    jge .u8done
    cmp rax, rsi
    jge .u8done
    movzx r10d, byte [rdi + rax]
    cmp r10b, 0x80
    jb .u8_1
    cmp r10b, 0xe0
    jb .u8_2
    cmp r10b, 0xf0
    jb .u8_3
    add rax, 4
    jmp .u8inc
.u8_1:
    inc rax
    jmp .u8inc
.u8_2:
    add rax, 2
    jmp .u8inc
.u8_3:
    add rax, 3
.u8inc:
    inc r9
    jmp .u8walk
.u8done:
    ret
END_FUNC sre_utf8_codepoint_to_byte

section .rodata
; (category tables are inline in sre_category above)
sre_recursion_err_msg: db "maximum recursion limit exceeded in regex", 0
