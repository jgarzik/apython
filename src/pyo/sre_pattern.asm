; sre_pattern.asm - SRE_Pattern type implementation
; Provides match/search/fullmatch/findall/finditer/sub/subn/split methods.

%include "macros.inc"
%include "object.inc"
%include "sre.inc"

extern bytes_type
extern ap_malloc
extern ap_free
extern ap_realloc
extern obj_decref
extern obj_incref
extern obj_dealloc
extern str_from_cstr_heap
extern str_new_heap
extern str_concat
extern dict_new
extern list_new
extern list_append
extern tuple_new
extern none_singleton
extern raise_exception
extern exc_TypeError_type
extern type_type
extern str_type
extern builtin_func_new
extern method_new
extern func_type
extern method_type
extern builtin_func_type
extern bool_true
extern bool_false
; SRE engine functions
extern sre_match
extern sre_template_parse
extern sre_template_expand
extern raise_type_error_counted
extern sre_state_reset_marks
extern sre_search
extern sre_state_init
extern sre_state_fini
extern sre_string_len
extern sre_utf8_codepoint_to_byte

; SRE match object
extern sre_match_new

;; ============================================================================
;; Forward declarations
;; ============================================================================

;; ============================================================================
;; sre_pattern_dealloc(PyObject* self)
;; ============================================================================
DEF_FUNC sre_pattern_dealloc, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi

    ; DECREF pattern string
    mov rdi, [rbx + SRE_PatternObject.pattern]
    test rdi, rdi
    jz .no_pattern
    call obj_decref
.no_pattern:

    ; DECREF groupindex
    mov rdi, [rbx + SRE_PatternObject.groupindex]
    test rdi, rdi
    jz .no_gi
    call obj_decref
.no_gi:

    ; DECREF indexgroup
    mov rdi, [rbx + SRE_PatternObject.indexgroup]
    test rdi, rdi
    jz .no_ig
    call obj_decref
.no_ig:

    ; Free code array
    mov rdi, [rbx + SRE_PatternObject.code]
    test rdi, rdi
    jz .no_code
    call ap_free
.no_code:

    ; Free object
    mov rdi, rbx
    call ap_free

    pop rbx
    leave
    ret
END_FUNC sre_pattern_dealloc

;; ============================================================================
;; sre_pattern_repr(PyObject* self) -> PyObject*
;; ============================================================================
DEF_FUNC sre_pattern_repr
    CSTRING rdi, "re.compile(...)"
    call str_from_cstr_heap
    leave
    ret
END_FUNC sre_pattern_repr

;; ============================================================================
;; Helper: run match/search/fullmatch and return MatchObject or None
;; rdi = pattern obj, rsi = string, rdx = pos, rcx = endpos,
;; r8 = mode (0=match, 1=search, 2=fullmatch)
;; ============================================================================
PM_PAT      equ 8
PM_STR      equ 16
PM_POS      equ 24
PM_ENDPOS   equ 32
PM_MODE     equ 40
PM_STATE    equ 40 + SRE_State_size  ; state base at BOTTOM of frame
PM_FRAME    equ 40 + SRE_State_size

DEF_FUNC sre_pattern_do_match, PM_FRAME
    push rbx
    push r12
    push r13
    push r14

    mov [rbp - PM_PAT], rdi
    mov [rbp - PM_STR], rsi
    mov [rbp - PM_POS], rdx
    mov [rbp - PM_ENDPOS], rcx
    mov [rbp - PM_MODE], r8

    ; Initialize state
    lea rdi, [rbp - PM_STATE]
    mov rsi, [rbp - PM_PAT]
    mov rdx, [rbp - PM_STR]
    mov rcx, [rbp - PM_POS]
    mov r8, [rbp - PM_ENDPOS]
    lea r9, [rel sre_shared_cpcache]   ; see its definition
    call sre_state_init

    ; Set fullmatch mode if applicable
    mov rax, [rbp - PM_MODE]
    cmp rax, 2
    jne .no_fullmatch
    lea rdi, [rbp - PM_STATE]
    mov dword [rdi + SRE_State.match_all], 1
.no_fullmatch:

    ; Run match or search
    mov rax, [rbp - PM_MODE]
    cmp rax, 1
    je .do_search

    ; match/fullmatch: try at pos only
    lea rdi, [rbp - PM_STATE]
    mov rax, [rdi + SRE_State.str_pos]
    mov [rdi + SRE_State.search_origin], rax
    mov rsi, [rbp - PM_PAT]
    mov rsi, [rsi + SRE_PatternObject.code]
    mov edx, 1                 ; this SUCCESS is the pattern's own
    call sre_match
    jmp .check_result

.do_search:
    lea rdi, [rbp - PM_STATE]
    call sre_search

.check_result:
    test eax, eax
    jz .no_match

    ; Create SRE_MatchObject
    lea rdi, [rbp - PM_STATE]
    mov rsi, [rbp - PM_PAT]
    mov rdx, [rbp - PM_STR]
    call sre_match_new
    mov r12, rax               ; match object

    ; Clean up state
    lea rdi, [rbp - PM_STATE]
    call sre_state_fini

    mov rax, r12
    mov edx, TAG_PTR

    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.no_match:
    lea rdi, [rbp - PM_STATE]
    call sre_state_fini

    ; Return None
    xor eax, eax
    RET_NONE

    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC sre_pattern_do_match

;; ============================================================================
;; sre_pattern_match_method(self, args, nargs)
;; Pattern.match(string, pos=0, endpos=sys.maxsize)
;; ============================================================================
;; ============================================================================
;; sp_arg_i64(rdi: argument Value) -> rax: int64
;;
;; pos/endpos arguments used to be read straight out of the payload word,
;; which is only correct while every integer is a SmallInt.  Normalize here
;; so bool, compact heap ints, GMP ints and int subclasses all work.
;; Clobbers rax, rcx, rdx, rdi, rsi, r8-r11 like any call.
;; ============================================================================
extern int_unwrap
extern int_to_i64
DEF_FUNC_LOCAL sp_arg_i64
    ; Preserves every register except rax; the callers keep the pattern,
    ; the string and the argument count live across these calls.
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    V_UNPACK rdi, rdx          ; the argument Value
    call int_unwrap
    cmp edx, TAG_SMALLINT
    je .sai_small
    ; int_to_i64 reads PyIntObject fields off whatever it is given, so a str
    ; pos fed __gmpz_get_si a garbage limb pointer.
    push rdi
    push rdx
    extern int_is_integer
    call int_is_integer
    pop rdx
    pop rdi
    test eax, eax
    jz .sai_type_error
    call int_to_i64
    jmp .sai_out
.sai_type_error:
    extern exc_TypeError_type
    extern raise_exception
    RAISE exc_TypeError_type, "an integer is required"
.sai_small:
    mov rax, rdi
.sai_out:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    leave
    ret
END_FUNC sp_arg_i64

DEF_FUNC sre_pattern_match_method
    ; rdi = args (fat array), rsi = nargs
    ; args[0] = self (pattern), args[1..] = user args
    push rbx
    push r12
    mov rbx, [rdi]             ; pattern = args[0] payload
    lea r12, [rdi + 8]         ; user args start at args[1]
    lea rdx, [rsi - 1]         ; user nargs

    ; Get string arg
    test rdx, rdx
    je .match_error
    mov rsi, [r12]             ; string payload

    ; Save user nargs for endpos check
    mov r8, rdx                ; r8 = user nargs

    ; pos (default 0)
    xor ecx, ecx
    cmp r8, 2
    jb .match_no_pos
    mov rdi, [r12 + 8]
    call sp_arg_i64
    mov rcx, rax               ; pos
.match_no_pos:
    mov rdx, rcx               ; rdx = pos

    ; endpos (default large)
    mov rcx, 0x7fffffffffffffff
    cmp r8, 3
    jb .match_no_endpos
    mov rdi, [r12 + 16]
    call sp_arg_i64
    mov rcx, rax               ; endpos
.match_no_endpos:

    mov rdi, rbx               ; pattern
    ; rsi already = string
    ; rdx = pos
    ; rcx = endpos
    xor r8d, r8d               ; mode = 0 (match)
    call sre_pattern_do_match

    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.match_error:
    RAISE exc_TypeError_type, "match() requires a string argument"
END_FUNC sre_pattern_match_method

;; ============================================================================
;; sre_pattern_search_method(self, args, nargs)
;; ============================================================================
DEF_FUNC sre_pattern_search_method, 8            ; 3 pushes, so rsp is 16-aligned
    ; rdi = args (fat array), rsi = nargs
    push rbx
    push r12
    push r13
    mov rbx, [rdi]             ; pattern = args[0] payload
    lea r12, [rdi + 8]         ; user args
    lea r13, [rsi - 1]         ; user nargs

    test r13, r13
    je .search_error
    mov rsi, [r12]             ; string payload

    ; pos (default 0)
    xor edx, edx
    cmp r13, 2
    jb .search_no_pos
    mov rdi, [r12 + 8]
    call sp_arg_i64
    mov rdx, rax               ; pos
.search_no_pos:

    ; endpos (default max)
    mov rcx, 0x7fffffffffffffff
    cmp r13, 3
    jb .search_no_endpos
    mov rdi, [r12 + 16]
    call sp_arg_i64
    mov rcx, rax               ; endpos
.search_no_endpos:

    mov rdi, rbx
    mov r8d, 1                 ; mode = search
    call sre_pattern_do_match

    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.search_error:
    RAISE exc_TypeError_type, "search() requires a string argument"
END_FUNC sre_pattern_search_method

;; ============================================================================
;; sre_pattern_fullmatch_method(self, args, nargs)
;; ============================================================================
DEF_FUNC sre_pattern_fullmatch_method, 8            ; 3 pushes, so rsp is 16-aligned
    ; rdi = args (fat array), rsi = nargs
    push rbx
    push r12
    push r13
    mov rbx, [rdi]             ; pattern = args[0] payload
    lea r12, [rdi + 8]         ; user args
    lea r13, [rsi - 1]         ; user nargs

    test r13, r13
    je .fm_error
    mov rsi, [r12]             ; string payload

    ; pos (default 0)
    xor edx, edx
    cmp r13, 2
    jb .fm_no_pos
    mov rdi, [r12 + 8]
    call sp_arg_i64
    mov rdx, rax               ; pos
.fm_no_pos:

    ; endpos (default max)
    mov rcx, 0x7fffffffffffffff
    cmp r13, 3
    jb .fm_no_endpos
    mov rdi, [r12 + 16]
    call sp_arg_i64
    mov rcx, rax               ; endpos
.fm_no_endpos:

    mov rdi, rbx
    mov r8d, 2                 ; mode = fullmatch
    call sre_pattern_do_match

    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.fm_error:
    RAISE exc_TypeError_type, "fullmatch() requires a string argument"
END_FUNC sre_pattern_fullmatch_method

;; ============================================================================
;; sre_substr_from_state_empty(rdi=state, rsi=start_idx, rdx=end_idx)
;; -> (rax=payload, edx=tag)
;;
;; The same, except that an unmatched group is the empty string rather than
;; None.  CPython has both -- state_getslice's `empty` argument -- and which
;; one a caller wants is not a detail: findall gives '' for a group that did
;; not match, split gives None, and they read the same marks to do it.
;; ============================================================================
DEF_FUNC sre_substr_from_state_empty
    cmp rsi, -1
    je .sse_empty
    cmp rdx, -1
    je .sse_empty
    call sre_substr_from_state
    leave
    ret
.sse_empty:
    mov edx, [rdi + SRE_State.is_bytes]
    lea rdi, [rel sse_nothing]
    xor esi, esi
    call sre_new_slice
    leave
    ret

;; ============================================================================
;; sre_shared_cpcache -- one decoded subject, shared by every pattern method
;; that has no scanner of its own to hold one.
;;
;; The engine indexes CODE POINTS, so a non-ASCII subject is decoded to u32
;; before matching, and that is O(len).  finditer has a scanner and pays it
;; once; a hand-written `while m := p.search(s, pos)` loop had nothing to hold
;; the decode and paid it per call, which is quadratic over the subject.
;; json.decoder is written exactly that way.
;;
;; One entry is enough for the shape that matters -- a loop walks ONE subject
;; -- and it is keyed on the string, so alternating between two merely costs
;; what it cost before.  The key is an OWNED reference: without one, a freed
;; string whose address the allocator reused would read as a hit and the
;; engine would index a stale decode.
;; ============================================================================
section .bss
align 8
sre_shared_cpcache: resq 4      ; an SRE_CpCache: buf, len, subject, borrows

section .text

section .rodata
sse_nothing: db 0
section .text
END_FUNC sre_substr_from_state_empty

;; ============================================================================
;; sre_substr_from_state(rdi=state, rsi=start_idx, rdx=end_idx)
;; -> (rax=payload, edx=tag)
;; Extracts substring handling both ASCII and codepoint modes.
;; Returns (0, TAG_NONE) if start or end is -1.
;; ============================================================================
DEF_FUNC sre_substr_from_state
    ; Check for unmatched group
    cmp rsi, -1
    je .ss_none
    cmp rdx, -1
    je .ss_none

    push rbx
    push r12
    push r13
    push r14

    mov rbx, rdi               ; state
    mov r12, rsi               ; start codepoint index
    mov r13, rdx               ; end codepoint index

    ; Check ASCII or Unicode mode
    mov rax, [rbx + SRE_State.codepoint_buf]
    test rax, rax
    jnz .ss_unicode

    ; ASCII mode: byte index = codepoint index.  A bytes subject is always
    ; here, and its slices are bytes.
    mov rdi, [rbx + SRE_State.str_begin]
    add rdi, r12
    mov rsi, r13
    sub rsi, r12
    mov edx, [rbx + SRE_State.is_bytes]
    extern sre_new_slice
    call sre_new_slice

    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.ss_unicode:
    ; Unicode mode: use shared UTF-8 walker to find byte offsets
    mov rdi, [rbx + SRE_State.str_begin]
    mov rsi, [rbx + SRE_State.str_end]
    sub rsi, rdi               ; total byte length

    ; Find byte offset for start codepoint index (r12)
    mov rdx, r12               ; target = start codepoint idx
    xor ecx, ecx               ; start_byte = 0
    xor r8d, r8d               ; start_cp = 0
    push rdi                   ; save str_begin
    push rsi                   ; save byte_len
    call sre_utf8_codepoint_to_byte
    mov r14, rax               ; r14 = start byte offset

    ; Find byte offset for end codepoint index (r13)
    pop rsi                    ; restore byte_len
    pop rdi                    ; restore str_begin
    mov rdx, r13               ; target = end codepoint idx
    mov rcx, r14               ; start_byte = start offset
    mov r8, r12                ; start_cp = start idx
    call sre_utf8_codepoint_to_byte
    ; rax = end byte offset, r14 = start byte offset

    ; Create substring from byte offsets
    mov rdi, [rbx + SRE_State.str_begin]
    add rdi, r14
    mov rsi, rax
    sub rsi, r14
    call str_new_heap
    mov edx, TAG_PTR

    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.ss_none:
    xor eax, eax
    RET_NONE
    leave
    ret
END_FUNC sre_substr_from_state

;; ============================================================================
;; sre_pattern_findall_method(self, args, nargs)
;; Returns list of all non-overlapping matches.
;; If pattern has no groups: list of matched strings.
;; If 1 group: list of group(1) strings.
;; If >1 groups: list of tuples.
;; ============================================================================
FA_PAT      equ 8
FA_STR      equ 16
FA_LIST     equ 24
FA_STATE    equ 24 + SRE_State_size   ; state base at BOTTOM of frame
FA_FRAME    equ 24 + SRE_State_size

DEF_FUNC sre_pattern_findall_method, FA_FRAME
    ; rdi = args (fat array), rsi = nargs
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rax, [rdi]             ; pattern = args[0] payload
    mov [rbp - FA_PAT], rax
    lea rdx, [rsi - 1]         ; user nargs
    test rdx, rdx
    je .fa_error

    mov rax, [rdi + 8]       ; string = args[1] payload
    mov [rbp - FA_STR], rax

    ; pos (default 0)
    xor ecx, ecx
    cmp rdx, 2
    jb .fa_no_pos
    push rdi
    mov rdi, [rdi + 16]
    call sp_arg_i64
    pop rdi
    mov rcx, rax               ; args[2] = pos
.fa_no_pos:
    push rcx                   ; save pos

    ; endpos (default max)
    mov r8, 0x7fffffffffffffff
    cmp rdx, 3
    jb .fa_no_endpos
    push rdi
    mov rdi, [rdi + 24]
    call sp_arg_i64
    pop rdi
    mov r8, rax                ; args[3] = endpos
.fa_no_endpos:
    push r8                    ; save endpos

    ; Create result list
    xor edi, edi
    call list_new
    mov [rbp - FA_LIST], rax
    mov r14, rax               ; r14 = result list

    ; Init state
    pop r8                     ; endpos
    pop rcx                    ; pos
    lea rdi, [rbp - FA_STATE]
    mov rsi, [rbp - FA_PAT]
    mov rdx, [rbp - FA_STR]
    lea r9, [rel sre_shared_cpcache]   ; see its definition
    call sre_state_init

    mov r12, [rbp - FA_PAT]   ; pattern
    mov r15d, [r12 + SRE_PatternObject.groups]  ; number of groups

.fa_loop:
    ; Reset marks
    lea rdi, [rbp - FA_STATE]
    call sre_state_reset_marks

    ; Search
    lea rdi, [rbp - FA_STATE]
    call sre_search
    test eax, eax
    jz .fa_done

    ; Found a match. What to append depends on groups.
    test r15d, r15d
    je .fa_no_groups
    cmp r15d, 1
    je .fa_one_group

    ; Multiple groups: create tuple of group strings
    jmp .fa_multi_groups

.fa_no_groups:
    ; Append matched substring (group 0)
    lea rdi, [rbp - FA_STATE]
    mov rsi, [rdi + SRE_State.str_start]  ; match start
    mov rdx, [rdi + SRE_State.str_pos]    ; match end
    call sre_substr_from_state
    ; rax = str payload, edx = tag
    mov rdi, r14
    mov rsi, rax
    ; edx already set
    push rax
    push rdx
    V_PACK rsi, rdx         ; list_append takes a Value
    call list_append
    pop rdx
    pop rax
    DECREF_VAL rax, rdx
    lea rdi, [rbp - FA_STATE]
    mov rcx, [rdi + SRE_State.str_pos]
    jmp .fa_advance

.fa_one_group:
    ; Append group(1) string.
    ; State marks[0:1] = group 1 in CPython convention.
    ;
    ; A group that did not match is the empty string, not the whole match:
    ; this used to fall through to .fa_no_groups when marks_size said the
    ; group was never set, so re.findall('(a)?b', 'b') answered ['b'] where
    ; CPython answers [''].  The marks now carry -1 for a hole, so the only
    ; thing to guard is the array's own length.
    lea rdi, [rbp - FA_STATE]
    mov rax, [rdi + SRE_State.marks]
    mov rsi, -1
    mov rdx, -1
    cmp qword [rdi + SRE_State.marks_count], 2
    jb .fa_og_have
    mov rsi, [rax]            ; mark[0] = group 1 start
    mov rdx, [rax + 8]       ; mark[1] = group 1 end
.fa_og_have:
    lea rdi, [rbp - FA_STATE]
    call sre_substr_from_state_empty
    ; rax = payload, edx = tag (str or None)
    mov rdi, r14
    mov rsi, rax
    ; edx already set
    push rax
    push rdx
    V_PACK rsi, rdx         ; list_append takes a Value
    call list_append
    pop rdx
    pop rax
    DECREF_VAL rax, rdx
    lea rdi, [rbp - FA_STATE]
    mov rcx, [rdi + SRE_State.str_pos]
    jmp .fa_advance

.fa_multi_groups:
    ; Create tuple of group(1)..group(N) strings
    mov edi, r15d              ; N groups
    push r15
    call tuple_new
    pop r15
    mov rbx, rax               ; rbx = tuple

    mov ecx, 1                 ; group index (1-based)
.fa_mg_loop:
    cmp ecx, r15d
    ja .fa_mg_done
    push rcx

    ; Get marks for group ecx: state marks[2*(ecx-1)] and marks[2*(ecx-1)+1]
    ; State marks are 0-based: MARK 0/1 = group 1, MARK 2/3 = group 2, etc.
    lea rdi, [rbp - FA_STATE]
    mov rax, [rdi + SRE_State.marks]
    movsx r8, ecx
    dec r8                     ; r8 = group - 1
    shl r8, 1                  ; r8 = 2 * (group - 1)
    ; Check marks_size > 2*(group-1)+1
    lea r9, [r8 + 2]
    cmp r9, [rdi + SRE_State.marks_count]
    ja .fa_mg_unset

    mov rsi, [rax + r8*8]     ; start
    mov rdx, [rax + r8*8 + 8] ; end
    jmp .fa_mg_call
.fa_mg_unset:
    ; Past the end of the array: never marked, same as a -1 hole in it.
    mov rsi, -1
    mov rdx, -1
.fa_mg_call:
    lea rdi, [rbp - FA_STATE]
    call sre_substr_from_state_empty
    jmp .fa_mg_set

.fa_mg_set:
    ; Set tuple[group-1] = (rax, edx)
    ; Fresh strings from sre_substr_from_state have refcount=1;
    ; tuple takes ownership without INCREF. TAG_NONE has no RC_BIT.
    pop rcx
    push rcx
    lea esi, [ecx - 1]
    movsx rsi, esi
    mov r8, [rbx + PyTupleObject.ob_item]       ; payloads
    V_PACK rax, rdx
    mov [r8 + rsi * 8], rax

    pop rcx
    inc ecx
    jmp .fa_mg_loop

.fa_mg_done:
    ; Append tuple to list
    mov rdi, r14
    mov rsi, rbx
    call list_append
    mov rdi, rbx
    call obj_decref
    lea rdi, [rbp - FA_STATE]
    mov rcx, [rdi + SRE_State.str_pos]
    jmp .fa_advance

.fa_advance:
    ; Advance position past the match.
    ;
    ; An empty match does NOT step past itself.  CPython stopped doing that in
    ; 3.7: it searches the same position again with must_advance set, which
    ; forbids a second empty match there and so makes the engine keep
    ; backtracking.  Stepping instead threw away everything it would have
    ; found -- findall('.*?', 'aab') was ['', '', '', ''] rather than
    ; ['', 'a', '', 'a', '', 'b', ''].
    lea rdi, [rbp - FA_STATE]
    mov rax, [rdi + SRE_State.str_start]
    mov dword [rdi + SRE_State.must_advance], 0
    cmp rcx, rax
    jne .fa_advance_ok
    mov dword [rdi + SRE_State.must_advance], 1
.fa_advance_ok:
    lea rdi, [rbp - FA_STATE]
    mov [rdi + SRE_State.str_pos], rcx
    mov [rdi + SRE_State.str_start], rcx

    ; Check if past end
    push rcx
    lea rdi, [rbp - FA_STATE]
    call sre_string_len
    pop rcx
    cmp rcx, rax
    ja .fa_done

    jmp .fa_loop

.fa_done:
    lea rdi, [rbp - FA_STATE]
    call sre_state_fini

    mov rax, r14
    mov edx, TAG_PTR

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.fa_error:
    RAISE exc_TypeError_type, "findall() requires a string argument"
END_FUNC sre_pattern_findall_method

;; ============================================================================
;; sre_pattern_sub_method(self, args, nargs)
;; Pattern.sub(repl, string, count=0)
;; ============================================================================
SUB_PAT      equ 8
SUB_REPL     equ 16
SUB_STR      equ 24
SUB_COUNT    equ 32
SUB_RESULT   equ 40
SUB_NSUBS    equ 48
SUB_LASTEND  equ 56
SUB_CALLABLE equ 64
SUB_REPL_TAG equ 72
; The parsed replacement template, and the single literal it collapses to
; when it names no group.  Both sit above the state struct, which starts at
; SUB_STATE and grows downward from there.
SUB_TMPL     equ 80
SUB_LITERAL  equ 88
; How many pieces CPython's list would hold so far, and the index of the
; first that is not the pattern's kind (-1 for none) -- see .sub_mismatch.
SUB_NPIECES  equ 96
SUB_BADIDX   equ 104
SUB_STATE    equ 104 + SRE_State_size
SUB_FRAME    equ 104 + SRE_State_size

DEF_FUNC sre_pattern_sub_method, SUB_FRAME
    ; rdi = args (fat array), rsi = nargs
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rax, [rdi]             ; pattern = args[0] payload
    mov [rbp - SUB_PAT], rax
    lea rdx, [rsi - 1]         ; user nargs
    cmp rdx, 2
    jb .sub_error

    ; repl = user_args[0], string = user_args[1]
    mov rax, [rdi + 8]       ; args[1] = repl
    V_UNPACK rax, rcx
    mov [rbp - SUB_REPL], rax
    mov [rbp - SUB_REPL_TAG], rcx
    mov rax, [rdi + 16]       ; args[2] = string
    mov [rbp - SUB_STR], rax

    ; Check if repl is callable by type whitelist
    ; (tp_call check alone fails because add_builtin_type patches tp_call
    ;  on str_type/int_type/etc. for constructor use, making all instances
    ;  appear callable)
    mov qword [rbp - SUB_CALLABLE], 0
    cmp ecx, TAG_PTR
    jne .sub_repl_not_callable
    mov rax, [rbp - SUB_REPL]
    mov rax, [rax + PyObject.ob_type]  ; type(repl)
    lea rcx, [rel func_type]
    cmp rax, rcx
    je .sub_is_callable
    lea rcx, [rel method_type]
    cmp rax, rcx
    je .sub_is_callable
    lea rcx, [rel builtin_func_type]
    cmp rax, rcx
    je .sub_is_callable
    lea rcx, [rel type_type]
    cmp rax, rcx
    je .sub_is_callable
    ; Heaptype with tp_call (user class with __call__): check tp_call
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_HEAPTYPE
    jz .sub_repl_not_callable
.sub_is_callable:
    mov rax, [rax + PyTypeObject.tp_call]
    test rax, rax
    jz .sub_repl_not_callable
    mov [rbp - SUB_CALLABLE], rax
.sub_repl_not_callable:

    ; count = user_args[2] if user_nargs >= 3, else 0
    xor eax, eax
    cmp rdx, 3
    jb .sub_no_count
    push rdi
    mov rdi, [rdi + 24]       ; args[3] = count
    call sp_arg_i64
    pop rdi
.sub_no_count:
    mov [rbp - SUB_COUNT], rax
    mov qword [rbp - SUB_NSUBS], 0
    mov qword [rbp - SUB_LASTEND], 0
    mov qword [rbp - SUB_NPIECES], 0
    mov qword [rbp - SUB_BADIDX], -1

    ; Create the empty result -- "" or b"", whichever the pattern is.
    mov rax, [rbp - SUB_PAT]
    mov edx, [rax + SRE_PatternObject.is_bytes]
    extern sre_empty
    call sre_empty
    mov [rbp - SUB_RESULT], rax

    ; A string replacement is a template, not a literal: \1, \g<name> and the
    ; escapes all mean something.  It is parsed once here, as CPython's
    ; _compile_template is, rather than per match.  A template that names no
    ; group collapses to a single literal, and that keeps the old fast path --
    ; no match object is built for it.
    mov qword [rbp - SUB_TMPL], 0
    mov qword [rbp - SUB_LITERAL], 0
    cmp qword [rbp - SUB_CALLABLE], 0
    jnz .sub_have_template
    mov rax, [rbp - SUB_REPL]
    ; A replacement that is neither callable nor a str is CPython's
    ; TypeError.  Falling through instead left SUB_TMPL and SUB_LITERAL at 0
    ; and .sub_expand_repl dereferenced the NULL -- and the exact type
    ; compare sent a str SUBCLASS down that same road, where the sibling
    ; Match.expand went out of its way to accept one.
    ; The slot holds a PAYLOAD, not a Value -- the tag is beside it -- so an
    ; int immediate of 5 looks exactly like the address 5 to V_TEST_PTR.
    cmp qword [rbp - SUB_REPL_TAG], TAG_PTR
    jne .sub_repl_type
    test rax, rax
    jz .sub_repl_type
    ; A str or a bytes, whichever the pattern is: CPython parses either
    ; against either, and a kind that differs from the pattern's fails only
    ; when a substitution is actually made -- in the join that assembles the
    ; result, which .sub_mismatch defers to the end.  With no match the string
    ; comes back untouched; tabulate relies on exactly that.
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel bytes_type]
    cmp rcx, rdx
    je .sub_repl_ok
    test qword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_BYTES_SUBCLASS
    jnz .sub_repl_ok
    REQUIRE_STR_TYPE rcx, rdx, .sub_repl_type
.sub_repl_ok:

    mov rdi, rax
    mov rsi, [rbp - SUB_PAT]
    call sre_template_parse
    mov [rbp - SUB_TMPL], rax
    mov rcx, [rax + PyListObject.ob_size]
    cmp rcx, 1
    ja .sub_have_template       ; it names at least one group
    jb .sub_empty_template
    mov rdx, [rax + PyListObject.ob_item]
    mov rdx, [rdx]
    V_TEST_PTR rdx, rcx
    ja .sub_have_template
    mov rcx, [rdx + PyObject.ob_type]
    lea rax, [rel str_type]
    cmp rcx, rax
    je .sub_single_literal
    lea rax, [rel bytes_type]
    cmp rcx, rax
    jne .sub_have_template
.sub_single_literal:
    mov [rbp - SUB_LITERAL], rdx
    mov rdi, rdx
    call obj_incref
    jmp .sub_have_template
.sub_empty_template:
    mov rax, [rbp - SUB_PAT]
    mov edx, [rax + SRE_PatternObject.is_bytes]
    call sre_empty
    mov [rbp - SUB_LITERAL], rax
    jmp .sub_have_template

.sub_repl_type:
    mov rsi, [rbp - SUB_REPL]
    mov rdx, [rbp - SUB_REPL_TAG]
    V_PACK rsi, rdx
    CSTRING rdi, `expected str instance, \x01 found`
    extern raise_type_error_with_name
    call raise_type_error_with_name

.sub_have_template:

    ; Init state
    lea rdi, [rbp - SUB_STATE]
    mov rsi, [rbp - SUB_PAT]
    mov rdx, [rbp - SUB_STR]
    xor ecx, ecx
    mov r8, 0x7fffffffffffffff
    lea r9, [rel sre_shared_cpcache]   ; see its definition
    call sre_state_init

.sub_loop:
    ; Check count limit
    mov rax, [rbp - SUB_COUNT]
    test rax, rax
    jz .sub_search              ; 0 means unlimited
    cmp [rbp - SUB_NSUBS], rax
    jge .sub_finish

.sub_search:
    lea rdi, [rbp - SUB_STATE]
    call sre_state_reset_marks
    call sre_search
    test eax, eax
    jz .sub_finish

    ; Get match start and end
    lea rdi, [rbp - SUB_STATE]
    mov r12, [rdi + SRE_State.str_start]  ; match start (char index)
    mov r13, [rdi + SRE_State.str_pos]    ; match end (char index)

    ; Append unmatched text before this match
    mov rax, [rbp - SUB_LASTEND]
    cmp rax, r12
    jge .sub_no_prefix
    ; Substring from lastend to match_start (Unicode-safe)
    lea rdi, [rbp - SUB_STATE]
    mov rsi, [rbp - SUB_LASTEND]
    mov rdx, r12
    call sre_substr_from_state
    ; Concat with result
    mov rdi, [rbp - SUB_RESULT]
    mov rsi, rax
    mov ecx, TAG_PTR
    push rax                   ; save for DECREF
    push rdi
    push rsi
    mov rax, [rbp - SUB_PAT]
    mov edx, [rax + SRE_PatternObject.is_bytes]
    pop rsi
    pop rdi
    extern sre_concat
    call sre_concat        ; str or bytes, as the pattern is
    push rax                   ; save new result
    mov rdi, [rbp - SUB_RESULT]
    call obj_decref
    pop rax
    mov [rbp - SUB_RESULT], rax
    pop rdi
    call obj_decref
    inc qword [rbp - SUB_NPIECES]
.sub_no_prefix:

    ; Get replacement: callable or string
    cmp qword [rbp - SUB_CALLABLE], 0
    jnz .sub_callable_repl

    ; String replacement.  A pure literal goes straight in; anything naming a
    ; group needs a match object to read the groups from.
    cmp qword [rbp - SUB_LITERAL], 0
    jz .sub_expand_repl
    mov rdi, [rbp - SUB_LITERAL]
    call .sub_mismatch
    jnz .sub_after_repl
    mov rdi, [rbp - SUB_RESULT]
    mov rsi, [rbp - SUB_LITERAL]
    mov ecx, TAG_PTR
    push rdi
    push rsi
    mov rax, [rbp - SUB_PAT]
    mov edx, [rax + SRE_PatternObject.is_bytes]
    pop rsi
    pop rdi
    extern sre_concat
    call sre_concat        ; str or bytes, as the pattern is
    jmp .sub_repl_concated

.sub_expand_repl:
    push r12
    push r13
    lea rdi, [rbp - SUB_STATE]
    mov rsi, [rbp - SUB_PAT]
    mov rdx, [rbp - SUB_STR]
    call sre_match_new
    push rax
    push rax                   ; a pair, so the calls stay 16-byte aligned
    mov rdi, [rbp - SUB_TMPL]
    mov rsi, rax
    call sre_template_expand
    pop rdi
    pop rdi                    ; the match object
    push rax
    push rax                   ; the expansion, ours
    call obj_decref
    pop rsi
    pop rsi
    push rsi
    push rsi
    mov rdi, rsi
    call .sub_mismatch
    jz .sub_expand_kind_ok
    pop rdi
    pop rdi                    ; the expansion, not wanted after all
    call obj_decref
    pop r13
    pop r12
    jmp .sub_after_repl
.sub_expand_kind_ok:
    mov rsi, [rsp]
    mov rdi, [rbp - SUB_RESULT]
    mov ecx, TAG_PTR
    push rdi
    push rsi
    mov rax, [rbp - SUB_PAT]
    mov edx, [rax + SRE_PatternObject.is_bytes]
    pop rsi
    pop rdi
    extern sre_concat
    call sre_concat        ; str or bytes, as the pattern is
    pop rdi
    pop rdi                    ; the expansion again
    push rax
    push rax                   ; the concatenation
    call obj_decref
    pop rax
    pop rax
    pop r13
    pop r12

.sub_repl_concated:
    push rax
    mov rdi, [rbp - SUB_RESULT]
    call obj_decref
    pop rax
    mov [rbp - SUB_RESULT], rax
    jmp .sub_after_repl

.sub_callable_repl:
    ; Create match object from current state
    push r12
    push r13
    lea rdi, [rbp - SUB_STATE]
    mov rsi, [rbp - SUB_PAT]
    mov rdx, [rbp - SUB_STR]
    call sre_match_new
    ; rax = match object
    mov r14, rax               ; r14 = match

    ; Build 1-arg fat array on stack: [match_payload, match_tag]
    sub rsp, 16                ; one Value; 16 keeps rsp aligned
    mov [rsp], r14             ; args[0] = the match object

    ; Call tp_call(repl, args, 1)
    mov rdi, [rbp - SUB_REPL]
    mov rsi, rsp               ; args ptr
    mov edx, 1                 ; nargs
    mov rax, [rbp - SUB_CALLABLE]
    call rax
    ; tp_call returns a Value, and str_concat below takes Values: unpacking
    ; here decoded it a second time, so a non-str replacement had its payload
    ; used as an address.
    add rsp, 16               ; pop fat array

    ; A NULL here means the callable RAISED, and it means nothing else -- a
    ; replacement of None is the none singleton, not 0.  Untested, the 0 went
    ; to sre_concat as a string and the exception the caller was owed came
    ; back as "expected str instance,  found", with the missing type name in
    ; the middle of the message where the NULL had been.
    test rax, rax
    jz .sub_callable_raised

    ; Save replacement string
    push rax
    push rax                  ; keep the stack 16-byte aligned

    ; DECREF match object
    mov rdi, r14
    call obj_decref

    ; Concat replacement with result.  sre_concat rejects anything that is
    ; not a string of the pattern's kind -- except None, which CPython's own
    ; sub() treats as "replace with nothing" rather than as an error.
    pop rsi                    ; (alignment copy)
    pop rsi                    ; the replacement Value
    push rsi                   ; save for DECREF
    push rsi                   ; alignment
    lea rax, [rel none_singleton]
    cmp rsi, rax
    je .sub_repl_none
    inc qword [rbp - SUB_NPIECES]
    mov rdi, [rbp - SUB_RESULT]
    push rdi
    push rsi
    mov rax, [rbp - SUB_PAT]
    mov edx, [rax + SRE_PatternObject.is_bytes]
    pop rsi
    pop rdi
    extern sre_concat
    call sre_concat        ; str or bytes, as the pattern is
    push rax
    push rax
    mov rdi, [rbp - SUB_RESULT]
    call obj_decref
    pop rax
    pop rax
    mov [rbp - SUB_RESULT], rax

.sub_repl_none:
    ; DECREF replacement string from tp_call
    pop rax
    pop rax
    mov rdi, rax
    XDECREF_V rdi, rdx

    pop r13
    pop r12

.sub_after_repl:
    ; Update state
    mov [rbp - SUB_LASTEND], r13
    inc qword [rbp - SUB_NSUBS]

    ; Advance past match -- an empty one stays put under must_advance; see
    ; .fa_advance in findall for why.
    lea rdi, [rbp - SUB_STATE]
    mov dword [rdi + SRE_State.must_advance], 0
    cmp r13, r12
    jne .sub_advance_ok
    mov dword [rdi + SRE_State.must_advance], 1
.sub_advance_ok:
    lea rdi, [rbp - SUB_STATE]
    mov [rdi + SRE_State.str_pos], r13
    mov [rdi + SRE_State.str_start], r13

    ; Check if past end
    push r13
    lea rdi, [rbp - SUB_STATE]
    call sre_string_len
    pop r13
    cmp r13, rax
    ja .sub_finish

    jmp .sub_loop

.sub_finish:
    mov rdi, [rbp - SUB_TMPL]
    test rdi, rdi
    jz .sub_tmpl_freed
    mov qword [rbp - SUB_TMPL], 0
    call obj_decref
    mov rdi, [rbp - SUB_LITERAL]
    test rdi, rdi
    jz .sub_tmpl_freed
    mov qword [rbp - SUB_LITERAL], 0
    call obj_decref
.sub_tmpl_freed:
    ; Append remaining text after last match (Unicode-safe)
    lea rdi, [rbp - SUB_STATE]
    call sre_string_len
    mov rcx, rax               ; string length
    mov rax, [rbp - SUB_LASTEND]
    cmp rax, rcx
    jge .sub_done

    lea rdi, [rbp - SUB_STATE]
    mov rsi, [rbp - SUB_LASTEND]
    mov rdx, rcx
    call sre_substr_from_state
    mov rdi, [rbp - SUB_RESULT]
    mov rsi, rax
    mov ecx, TAG_PTR
    push rax
    push rdi
    push rsi
    mov rax, [rbp - SUB_PAT]
    mov edx, [rax + SRE_PatternObject.is_bytes]
    pop rsi
    pop rdi
    extern sre_concat
    call sre_concat        ; str or bytes, as the pattern is
    push rax
    mov rdi, [rbp - SUB_RESULT]
    call obj_decref
    pop rax
    mov [rbp - SUB_RESULT], rax
    pop rdi
    call obj_decref

.sub_done:
    cmp qword [rbp - SUB_BADIDX], -1
    jne .sub_join_mismatch
    lea rdi, [rbp - SUB_STATE]
    call sre_state_fini

    mov rax, [rbp - SUB_RESULT]
    mov edx, TAG_PTR

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret


;; .sub_mismatch(rdi = a replacement piece, exactly a str or a bytes) -> ZF set
;; when it is the pattern's kind.  Either way it is one more piece of the
;; list CPython joins; the first that is not the pattern's kind is the item
;; the join refuses, and its index is remembered for .sub_join_mismatch.
;; Reached by `call` and calls nothing, so alignment is not its concern.
.sub_mismatch:
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel bytes_type]
    cmp rax, rcx
    sete al
    movzx eax, al
    mov rcx, [rbp - SUB_PAT]
    cmp eax, [rcx + SRE_PatternObject.is_bytes]
    je .sub_mismatch_ok
    cmp qword [rbp - SUB_BADIDX], -1
    jne .sub_mismatch_seen
    mov rax, [rbp - SUB_NPIECES]
    mov [rbp - SUB_BADIDX], rax
.sub_mismatch_seen:
    inc qword [rbp - SUB_NPIECES]
    or eax, 1                   ; ZF clear: the other kind
    ret
.sub_mismatch_ok:
    inc qword [rbp - SUB_NPIECES]
    xor eax, eax                ; ZF set: the pattern's kind
    ret

.sub_join_mismatch:
    ; The join's refusal, raised once the substitution is over, as CPython's
    ; join_list raises it: everything this frame owns goes first.
    mov rdi, [rbp - SUB_RESULT]
    mov qword [rbp - SUB_RESULT], 0
    call obj_decref
    lea rdi, [rbp - SUB_STATE]
    call sre_state_fini
    lea rdx, [rel sp_join_want_str]
    mov rax, [rbp - SUB_PAT]
    cmp qword [rax + SRE_PatternObject.is_bytes], 0
    je .sub_join_tail
    lea rdx, [rel sp_join_want_bytes]
.sub_join_tail:
    mov rsi, [rbp - SUB_BADIDX]
    lea rdi, [rel sp_join_item]
    call raise_type_error_counted     ; does not return

.sub_callable_raised:
    ; Give back the match the callable was handed and the two registers the
    ; call site parked, then unwind the whole substitution.
    mov rdi, r14
    call obj_decref
    pop r13
    pop r12

.sub_abort:
    ; Every owned thing this frame holds, then the state, then NULL -- the
    ; pending exception is already set and is what the caller must see.
    mov rdi, [rbp - SUB_TMPL]
    test rdi, rdi
    jz .sub_abort_tmpl
    mov qword [rbp - SUB_TMPL], 0
    call obj_decref
.sub_abort_tmpl:
    mov rdi, [rbp - SUB_LITERAL]
    test rdi, rdi
    jz .sub_abort_literal
    mov qword [rbp - SUB_LITERAL], 0
    call obj_decref
.sub_abort_literal:
    mov rdi, [rbp - SUB_RESULT]
    test rdi, rdi
    jz .sub_abort_result
    mov qword [rbp - SUB_RESULT], 0
    call obj_decref
.sub_abort_result:
    lea rdi, [rbp - SUB_STATE]
    call sre_state_fini
    xor eax, eax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.sub_error:
    RAISE exc_TypeError_type, "sub() requires repl and string arguments"
END_FUNC sre_pattern_sub_method

;; ============================================================================
;; sre_pattern_subn_method(self, args, nargs)
;; Like sub but returns (result, count) tuple.
;; Duplicated sub loop with count tracking.
;; ============================================================================
SN_PAT      equ 8
SN_REPL     equ 16
SN_STR      equ 24
SN_COUNT    equ 32
SN_RESULT   equ 40
SN_NSUBS    equ 48
SN_LASTEND  equ 56
SN_CALLABLE equ 64
SN_REPL_TAG equ 72
SN_TMPL     equ 80
SN_LITERAL  equ 88
; How many pieces CPython's list would hold so far, and the index of the
; first that is not the pattern's kind (-1 for none) -- see .subn_mismatch.
SN_NPIECES  equ 96
SN_BADIDX   equ 104
SN_STATE    equ 104 + SRE_State_size
SN_FRAME    equ 104 + SRE_State_size

DEF_FUNC sre_pattern_subn_method, SN_FRAME
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rax, [rdi]
    mov [rbp - SN_PAT], rax
    lea rdx, [rsi - 1]
    cmp rdx, 2
    jb .subn_error

    mov rax, [rdi + 8]
    V_UNPACK rax, rcx
    mov [rbp - SN_REPL], rax
    mov [rbp - SN_REPL_TAG], rcx
    mov rax, [rdi + 16]
    mov [rbp - SN_STR], rax

    ; Check if repl is callable by type whitelist
    mov qword [rbp - SN_CALLABLE], 0
    cmp ecx, TAG_PTR
    jne .subn_repl_not_callable
    mov rax, [rbp - SN_REPL]
    mov rax, [rax + PyObject.ob_type]  ; type(repl)
    lea rcx, [rel func_type]
    cmp rax, rcx
    je .subn_is_callable
    lea rcx, [rel method_type]
    cmp rax, rcx
    je .subn_is_callable
    lea rcx, [rel builtin_func_type]
    cmp rax, rcx
    je .subn_is_callable
    lea rcx, [rel type_type]
    cmp rax, rcx
    je .subn_is_callable
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_HEAPTYPE
    jz .subn_repl_not_callable
.subn_is_callable:
    mov rax, [rax + PyTypeObject.tp_call]
    test rax, rax
    jz .subn_repl_not_callable
    mov [rbp - SN_CALLABLE], rax
.subn_repl_not_callable:

    xor eax, eax
    cmp rdx, 3
    jb .subn_no_count
    push rdi
    mov rdi, [rdi + 24]
    call sp_arg_i64
    pop rdi
.subn_no_count:
    mov [rbp - SN_COUNT], rax
    mov qword [rbp - SN_NSUBS], 0
    mov qword [rbp - SN_LASTEND], 0
    mov qword [rbp - SN_NPIECES], 0
    mov qword [rbp - SN_BADIDX], -1

    mov rax, [rbp - SN_PAT]
    mov edx, [rax + SRE_PatternObject.is_bytes]
    call sre_empty
    mov [rbp - SN_RESULT], rax

    ; A string replacement is a template, not a literal: \1, \g<name> and the
    ; escapes all mean something.  It is parsed once here, as CPython's
    ; _compile_template is, rather than per match.  A template that names no
    ; group collapses to a single literal, and that keeps the old fast path --
    ; no match object is built for it.
    mov qword [rbp - SN_TMPL], 0
    mov qword [rbp - SN_LITERAL], 0
    cmp qword [rbp - SN_CALLABLE], 0
    jnz .subn_have_template
    mov rax, [rbp - SN_REPL]
    ; As in sub: neither callable nor a str is a TypeError, and a str
    ; subclass is a str.  Falling through left the template and the literal
    ; both NULL for the expander to dereference.
    ; The slot holds a PAYLOAD, not a Value -- the tag is beside it -- so an
    ; int immediate of 5 looks exactly like the address 5 to V_TEST_PTR.
    cmp qword [rbp - SN_REPL_TAG], TAG_PTR
    jne .subn_repl_type
    test rax, rax
    jz .subn_repl_type
    ; A str or a bytes, whichever the pattern is: CPython parses either
    ; against either, and a kind that differs from the pattern's fails only
    ; when a substitution is actually made -- in the join that assembles the
    ; result, which .subn_mismatch defers to the end.  With no match the string
    ; comes back untouched; tabulate relies on exactly that.
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel bytes_type]
    cmp rcx, rdx
    je .subn_repl_ok
    test qword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_BYTES_SUBCLASS
    jnz .subn_repl_ok
    REQUIRE_STR_TYPE rcx, rdx, .subn_repl_type
.subn_repl_ok:

    mov rdi, rax
    mov rsi, [rbp - SN_PAT]
    call sre_template_parse
    mov [rbp - SN_TMPL], rax
    mov rcx, [rax + PyListObject.ob_size]
    cmp rcx, 1
    ja .subn_have_template       ; it names at least one group
    jb .subn_empty_template
    mov rdx, [rax + PyListObject.ob_item]
    mov rdx, [rdx]
    V_TEST_PTR rdx, rcx
    ja .subn_have_template
    mov rcx, [rdx + PyObject.ob_type]
    lea rax, [rel str_type]
    cmp rcx, rax
    je .subn_single_literal
    lea rax, [rel bytes_type]
    cmp rcx, rax
    jne .subn_have_template
.subn_single_literal:
    mov [rbp - SN_LITERAL], rdx
    mov rdi, rdx
    call obj_incref
    jmp .subn_have_template
.subn_empty_template:
    mov rax, [rbp - SN_PAT]
    mov edx, [rax + SRE_PatternObject.is_bytes]
    call sre_empty
    mov [rbp - SN_LITERAL], rax
    jmp .subn_have_template

.subn_repl_type:
    mov rsi, [rbp - SN_REPL]
    mov rdx, [rbp - SN_REPL_TAG]
    V_PACK rsi, rdx
    CSTRING rdi, `expected str instance, \x01 found`
    call raise_type_error_with_name

.subn_have_template:

    lea rdi, [rbp - SN_STATE]
    mov rsi, [rbp - SN_PAT]
    mov rdx, [rbp - SN_STR]
    xor ecx, ecx
    mov r8, 0x7fffffffffffffff
    lea r9, [rel sre_shared_cpcache]   ; see its definition
    call sre_state_init

.subn_loop:
    mov rax, [rbp - SN_COUNT]
    test rax, rax
    jz .subn_search
    cmp [rbp - SN_NSUBS], rax
    jge .subn_finish

.subn_search:
    lea rdi, [rbp - SN_STATE]
    call sre_state_reset_marks
    call sre_search
    test eax, eax
    jz .subn_finish

    lea rdi, [rbp - SN_STATE]
    mov r12, [rdi + SRE_State.str_start]
    mov r13, [rdi + SRE_State.str_pos]

    mov rax, [rbp - SN_LASTEND]
    cmp rax, r12
    jge .subn_no_prefix
    lea rdi, [rbp - SN_STATE]
    mov rsi, [rbp - SN_LASTEND]
    mov rdx, r12
    call sre_substr_from_state
    mov rdi, [rbp - SN_RESULT]
    mov rsi, rax
    mov ecx, TAG_PTR
    push rax
    push rdi
    push rsi
    mov rax, [rbp - SN_PAT]
    mov edx, [rax + SRE_PatternObject.is_bytes]
    pop rsi
    pop rdi
    extern sre_concat
    call sre_concat        ; str or bytes, as the pattern is
    push rax
    mov rdi, [rbp - SN_RESULT]
    call obj_decref
    pop rax
    mov [rbp - SN_RESULT], rax
    pop rdi
    call obj_decref
    inc qword [rbp - SN_NPIECES]
.subn_no_prefix:

    ; Get replacement: callable or string
    cmp qword [rbp - SN_CALLABLE], 0
    jnz .subn_callable_repl

    ; String replacement.  A pure literal goes straight in; anything naming a
    ; group needs a match object to read the groups from.
    cmp qword [rbp - SN_LITERAL], 0
    jz .subn_expand_repl
    mov rdi, [rbp - SN_LITERAL]
    call .subn_mismatch
    jnz .subn_after_repl
    mov rdi, [rbp - SN_RESULT]
    mov rsi, [rbp - SN_LITERAL]
    mov ecx, TAG_PTR
    push rdi
    push rsi
    mov rax, [rbp - SN_PAT]
    mov edx, [rax + SRE_PatternObject.is_bytes]
    pop rsi
    pop rdi
    extern sre_concat
    call sre_concat        ; str or bytes, as the pattern is
    jmp .subn_repl_concated

.subn_expand_repl:
    push r12
    push r13
    lea rdi, [rbp - SN_STATE]
    mov rsi, [rbp - SN_PAT]
    mov rdx, [rbp - SN_STR]
    call sre_match_new
    push rax
    push rax                   ; a pair, so the calls stay 16-byte aligned
    mov rdi, [rbp - SN_TMPL]
    mov rsi, rax
    call sre_template_expand
    pop rdi
    pop rdi                    ; the match object
    push rax
    push rax                   ; the expansion, ours
    call obj_decref
    pop rsi
    pop rsi
    push rsi
    push rsi
    mov rdi, rsi
    call .subn_mismatch
    jz .subn_expand_kind_ok
    pop rdi
    pop rdi                    ; the expansion, not wanted after all
    call obj_decref
    pop r13
    pop r12
    jmp .subn_after_repl
.subn_expand_kind_ok:
    mov rsi, [rsp]
    mov rdi, [rbp - SN_RESULT]
    mov ecx, TAG_PTR
    push rdi
    push rsi
    mov rax, [rbp - SN_PAT]
    mov edx, [rax + SRE_PatternObject.is_bytes]
    pop rsi
    pop rdi
    extern sre_concat
    call sre_concat        ; str or bytes, as the pattern is
    pop rdi
    pop rdi                    ; the expansion again
    push rax
    push rax                   ; the concatenation
    call obj_decref
    pop rax
    pop rax
    pop r13
    pop r12

.subn_repl_concated:
    push rax
    mov rdi, [rbp - SN_RESULT]
    call obj_decref
    pop rax
    mov [rbp - SN_RESULT], rax
    jmp .subn_after_repl

.subn_callable_repl:
    ; Create match object
    push r12
    push r13
    lea rdi, [rbp - SN_STATE]
    mov rsi, [rbp - SN_PAT]
    mov rdx, [rbp - SN_STR]
    call sre_match_new
    mov r14, rax

    ; Build 1-arg fat array on stack
    sub rsp, 16                ; one Value; 16 keeps rsp aligned
    mov [rsp], r14

    ; Call tp_call(repl, args, 1)
    mov rdi, [rbp - SN_REPL]
    mov rsi, rsp
    mov edx, 1
    mov rax, [rbp - SN_CALLABLE]
    call rax
    V_UNPACK rax, rdx           ; tp_call returns a Value
    add rsp, 16

    ; The same NULL as in sub above: the callable raised.
    test rax, rax
    jz .subn_callable_raised

    push rax
    push rdx

    ; DECREF match
    mov rdi, r14
    call obj_decref

    ; Concat replacement
    pop rcx                    ; replacement tag
    pop rsi                    ; replacement payload
    push rsi                   ; save repl payload for DECREF
    push rcx                   ; save repl tag for DECREF
    inc qword [rbp - SN_NPIECES]
    mov rdi, [rbp - SN_RESULT]
    push rdi
    push rsi
    mov rax, [rbp - SN_PAT]
    mov edx, [rax + SRE_PatternObject.is_bytes]
    pop rsi
    pop rdi
    extern sre_concat
    call sre_concat        ; str or bytes, as the pattern is
    push rax
    mov rdi, [rbp - SN_RESULT]
    call obj_decref
    pop rax
    mov [rbp - SN_RESULT], rax

    ; DECREF replacement string from tp_call
    pop rdx                    ; repl tag
    pop rax                    ; repl payload
    DECREF_VAL rax, rdx

    pop r13
    pop r12

.subn_after_repl:
    mov [rbp - SN_LASTEND], r13
    inc qword [rbp - SN_NSUBS]

    lea rdi, [rbp - SN_STATE]
    mov dword [rdi + SRE_State.must_advance], 0
    cmp r13, r12
    jne .subn_advance_ok
    mov dword [rdi + SRE_State.must_advance], 1
.subn_advance_ok:
    lea rdi, [rbp - SN_STATE]
    mov [rdi + SRE_State.str_pos], r13
    mov [rdi + SRE_State.str_start], r13

    push r13
    lea rdi, [rbp - SN_STATE]
    call sre_string_len
    pop r13
    cmp r13, rax
    ja .subn_finish

    jmp .subn_loop

.subn_finish:
    mov rdi, [rbp - SN_TMPL]
    test rdi, rdi
    jz .subn_tmpl_freed
    mov qword [rbp - SN_TMPL], 0
    call obj_decref
    mov rdi, [rbp - SN_LITERAL]
    test rdi, rdi
    jz .subn_tmpl_freed
    mov qword [rbp - SN_LITERAL], 0
    call obj_decref
.subn_tmpl_freed:
    lea rdi, [rbp - SN_STATE]
    call sre_string_len
    mov rcx, rax
    mov rax, [rbp - SN_LASTEND]
    cmp rax, rcx
    jge .subn_build_tuple

    lea rdi, [rbp - SN_STATE]
    mov rsi, [rbp - SN_LASTEND]
    mov rdx, rcx
    call sre_substr_from_state
    mov rdi, [rbp - SN_RESULT]
    mov rsi, rax
    mov ecx, TAG_PTR
    push rax
    push rdi
    push rsi
    mov rax, [rbp - SN_PAT]
    mov edx, [rax + SRE_PatternObject.is_bytes]
    pop rsi
    pop rdi
    extern sre_concat
    call sre_concat        ; str or bytes, as the pattern is
    push rax
    mov rdi, [rbp - SN_RESULT]
    call obj_decref
    pop rax
    mov [rbp - SN_RESULT], rax
    pop rdi
    call obj_decref

.subn_build_tuple:
    cmp qword [rbp - SN_BADIDX], -1
    jne .subn_join_mismatch
    lea rdi, [rbp - SN_STATE]
    call sre_state_fini

    ; Create (result, nsubs) tuple
    mov edi, 2
    call tuple_new
    mov rbx, rax

    mov r8, [rbx + PyTupleObject.ob_item]       ; payloads

    mov r12, [rbp - SN_RESULT]
    inc qword [r12 + PyObject.ob_refcnt]
    mov [r8], r12

    mov rax, [rbp - SN_NSUBS]
    V_PACK_I64 rax, r9
    mov [r8 + 8], rax

    ; DECREF result string (tuple holds a ref)
    mov rdi, r12
    call obj_decref

    mov rax, rbx
    mov edx, TAG_PTR

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret


;; .subn_mismatch(rdi = a replacement piece, exactly a str or a bytes) -> ZF set
;; when it is the pattern's kind.  Either way it is one more piece of the
;; list CPython joins; the first that is not the pattern's kind is the item
;; the join refuses, and its index is remembered for .subn_join_mismatch.
;; Reached by `call` and calls nothing, so alignment is not its concern.
.subn_mismatch:
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel bytes_type]
    cmp rax, rcx
    sete al
    movzx eax, al
    mov rcx, [rbp - SN_PAT]
    cmp eax, [rcx + SRE_PatternObject.is_bytes]
    je .subn_mismatch_ok
    cmp qword [rbp - SN_BADIDX], -1
    jne .subn_mismatch_seen
    mov rax, [rbp - SN_NPIECES]
    mov [rbp - SN_BADIDX], rax
.subn_mismatch_seen:
    inc qword [rbp - SN_NPIECES]
    or eax, 1                   ; ZF clear: the other kind
    ret
.subn_mismatch_ok:
    inc qword [rbp - SN_NPIECES]
    xor eax, eax                ; ZF set: the pattern's kind
    ret

.subn_join_mismatch:
    ; The join's refusal, raised once the substitution is over, as CPython's
    ; join_list raises it: everything this frame owns goes first.
    mov rdi, [rbp - SN_RESULT]
    mov qword [rbp - SN_RESULT], 0
    call obj_decref
    lea rdi, [rbp - SN_STATE]
    call sre_state_fini
    lea rdx, [rel sp_join_want_str]
    mov rax, [rbp - SN_PAT]
    cmp qword [rax + SRE_PatternObject.is_bytes], 0
    je .subn_join_tail
    lea rdx, [rel sp_join_want_bytes]
.subn_join_tail:
    mov rsi, [rbp - SN_BADIDX]
    lea rdi, [rel sp_join_item]
    call raise_type_error_counted     ; does not return

.subn_callable_raised:
    mov rdi, r14
    call obj_decref
    pop r13
    pop r12

.subn_abort:
    mov rdi, [rbp - SN_TMPL]
    test rdi, rdi
    jz .subn_abort_tmpl
    mov qword [rbp - SN_TMPL], 0
    call obj_decref
.subn_abort_tmpl:
    mov rdi, [rbp - SN_LITERAL]
    test rdi, rdi
    jz .subn_abort_literal
    mov qword [rbp - SN_LITERAL], 0
    call obj_decref
.subn_abort_literal:
    mov rdi, [rbp - SN_RESULT]
    test rdi, rdi
    jz .subn_abort_result
    mov qword [rbp - SN_RESULT], 0
    call obj_decref
.subn_abort_result:
    lea rdi, [rbp - SN_STATE]
    call sre_state_fini
    xor eax, eax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.subn_error:
    RAISE exc_TypeError_type, "subn() requires repl and string arguments"
END_FUNC sre_pattern_subn_method

;; ============================================================================
;; sre_pattern_split_method(self, args, nargs)
;; Pattern.split(string, maxsplit=0)
;; ============================================================================
SP_PAT      equ 8
SP_STR      equ 16
SP_MAX      equ 24
SP_NSPLIT   equ 40
SP_LASTEND  equ 48
SP_STATE    equ 48 + SRE_State_size  ; state base at BOTTOM of frame
SP_FRAME    equ 48 + SRE_State_size

DEF_FUNC sre_pattern_split_method, SP_FRAME
    ; rdi = args (fat array), rsi = nargs
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rax, [rdi]             ; pattern = args[0] payload
    mov [rbp - SP_PAT], rax
    lea rdx, [rsi - 1]         ; user nargs
    test rdx, rdx
    je .split_error

    mov rax, [rdi + 8]       ; string = args[1] payload
    mov [rbp - SP_STR], rax

    ; maxsplit
    xor eax, eax
    cmp rdx, 2
    jb .split_no_max
    push rdi
    mov rdi, [rdi + 16]       ; args[2] = maxsplit
    call sp_arg_i64
    pop rdi
.split_no_max:
    mov [rbp - SP_MAX], rax
    mov qword [rbp - SP_NSPLIT], 0
    mov qword [rbp - SP_LASTEND], 0

    ; Create result list
    xor edi, edi
    call list_new
    mov r14, rax

    ; Get group count from pattern
    mov rax, [rbp - SP_PAT]
    mov r15d, [rax + SRE_PatternObject.groups]

    ; Init state
    lea rdi, [rbp - SP_STATE]
    mov rsi, [rbp - SP_PAT]
    mov rdx, [rbp - SP_STR]
    xor ecx, ecx
    mov r8, 0x7fffffffffffffff
    lea r9, [rel sre_shared_cpcache]   ; see its definition
    call sre_state_init

.split_loop:
    mov rax, [rbp - SP_MAX]
    test rax, rax
    jz .split_search
    cmp [rbp - SP_NSPLIT], rax
    jge .split_finish

.split_search:
    lea rdi, [rbp - SP_STATE]
    call sre_state_reset_marks
    call sre_search
    test eax, eax
    jz .split_finish

    lea rdi, [rbp - SP_STATE]
    mov r12, [rdi + SRE_State.str_start]
    mov r13, [rdi + SRE_State.str_pos]

    ; An empty match at the position the last one ended used to be skipped
    ; outright, which dropped re.split('x*', 'abc')'s leading ''.  must_advance
    ; is what keeps that from looping now, so the skip is not needed and was
    ; only ever wrong.

    ; Append text before match using sre_substr_from_state
    lea rdi, [rbp - SP_STATE]
    mov rsi, [rbp - SP_LASTEND]
    mov rdx, r12
    call sre_substr_from_state
    mov rdi, r14
    mov rsi, rax
    ; edx already set
    push rax
    push rdx
    V_PACK rsi, rdx         ; list_append takes a Value
    call list_append
    pop rdx
    pop rax
    DECREF_VAL rax, rdx

    ; Append capturing groups 1..N
    test r15d, r15d
    jz .split_no_captures
    mov ebx, 1                 ; group index
.split_cap_loop:
    cmp ebx, r15d
    ja .split_no_captures
    push rbx
    ; Get marks for group ebx: state marks[2*(ebx-1)] and marks[2*(ebx-1)+1]
    lea rdi, [rbp - SP_STATE]
    mov rax, [rdi + SRE_State.marks]
    movsx r8, ebx
    dec r8                     ; group - 1
    shl r8, 1                  ; 2 * (group - 1)
    lea r9, [r8 + 2]
    cmp r9, [rdi + SRE_State.marks_size]
    ja .split_cap_none

    mov rsi, [rax + r8*8]     ; start
    mov rdx, [rax + r8*8 + 8] ; end
    lea rdi, [rbp - SP_STATE]
    call sre_substr_from_state
    jmp .split_cap_append

.split_cap_none:
    xor eax, eax
    RET_NONE

.split_cap_append:
    mov rdi, r14
    mov rsi, rax
    ; edx already set
    push rax
    push rdx
    V_PACK rsi, rdx         ; list_append takes a Value
    call list_append
    pop rdx
    pop rax
    DECREF_VAL rax, rdx

    pop rbx
    inc ebx
    jmp .split_cap_loop

.split_no_captures:
    mov [rbp - SP_LASTEND], r13
    inc qword [rbp - SP_NSPLIT]

.split_advance_skip:
    ; Advance
    lea rdi, [rbp - SP_STATE]
    mov dword [rdi + SRE_State.must_advance], 0
    cmp r13, r12
    jne .split_adv_ok
    mov dword [rdi + SRE_State.must_advance], 1
.split_adv_ok:
    lea rdi, [rbp - SP_STATE]
    mov [rdi + SRE_State.str_pos], r13
    mov [rdi + SRE_State.str_start], r13

    push r13
    lea rdi, [rbp - SP_STATE]
    call sre_string_len
    pop r13
    cmp r13, rax
    ja .split_finish
    jmp .split_loop

.split_finish:
    ; Append remaining text using sre_substr_from_state
    lea rdi, [rbp - SP_STATE]
    call sre_string_len
    mov rcx, rax               ; string length
    mov rsi, [rbp - SP_LASTEND]
    lea rdi, [rbp - SP_STATE]
    mov rdx, rcx
    call sre_substr_from_state
    mov rdi, r14
    mov rsi, rax
    ; edx already set
    push rax
    push rdx
    V_PACK rsi, rdx         ; list_append takes a Value
    call list_append
    pop rdx
    pop rax
    DECREF_VAL rax, rdx

    lea rdi, [rbp - SP_STATE]
    call sre_state_fini

    mov rax, r14
    mov edx, TAG_PTR

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.split_error:
    RAISE exc_TypeError_type, "split() requires a string argument"
END_FUNC sre_pattern_split_method

;; ============================================================================
;; sre_pattern_getattr(PyObject* self, PyObject* name) -> rax = Value
;; ============================================================================
DEF_FUNC sre_pattern_getattr
    push rbx
    push r12

    mov rbx, rdi               ; self (pattern)
    mov r12, rsi               ; name string

    ; Get name as C string
    lea rdi, [r12 + PyStrObject.data]

    ; Check known attributes
    lea rsi, [rel sp_match_str]
    call sre_strcmp
    test eax, eax
    jz .ga_match

    lea rdi, [r12 + PyStrObject.data]
    lea rsi, [rel sp_search_str]
    call sre_strcmp
    test eax, eax
    jz .ga_search

    lea rdi, [r12 + PyStrObject.data]
    lea rsi, [rel sp_fullmatch_str]
    call sre_strcmp
    test eax, eax
    jz .ga_fullmatch

    lea rdi, [r12 + PyStrObject.data]
    lea rsi, [rel sp_findall_str]
    call sre_strcmp
    test eax, eax
    jz .ga_findall

    lea rdi, [r12 + PyStrObject.data]
    lea rsi, [rel sp_sub_str]
    call sre_strcmp
    test eax, eax
    jz .ga_sub

    lea rdi, [r12 + PyStrObject.data]
    lea rsi, [rel sp_subn_str]
    call sre_strcmp
    test eax, eax
    jz .ga_subn

    lea rdi, [r12 + PyStrObject.data]
    lea rsi, [rel sp_split_str]
    call sre_strcmp
    test eax, eax
    jz .ga_split

    lea rdi, [r12 + PyStrObject.data]
    lea rsi, [rel sp_pattern_str]
    call sre_strcmp
    test eax, eax
    jz .ga_pattern_attr

    lea rdi, [r12 + PyStrObject.data]
    lea rsi, [rel sp_flags_str]
    call sre_strcmp
    test eax, eax
    jz .ga_flags

    lea rdi, [r12 + PyStrObject.data]
    lea rsi, [rel sp_groups_str]
    call sre_strcmp
    test eax, eax
    jz .ga_groups

    lea rdi, [r12 + PyStrObject.data]
    lea rsi, [rel sp_groupindex_str]
    call sre_strcmp
    test eax, eax
    jz .ga_groupindex

    lea rdi, [r12 + PyStrObject.data]
    lea rsi, [rel sp_finditer_str]
    call sre_strcmp
    test eax, eax
    jz .ga_finditer

    lea rdi, [r12 + PyStrObject.data]
    lea rsi, [rel sp_scanner_str]
    call sre_strcmp
    test eax, eax
    jz .ga_scanner

    lea rdi, [r12 + PyStrObject.data]
    lea rsi, [rel sp_copy_str]
    call sre_strcmp
    test eax, eax
    jz .ga_copy

    lea rdi, [r12 + PyStrObject.data]
    lea rsi, [rel sp_deepcopy_str]
    call sre_strcmp
    test eax, eax
    jz .ga_copy

    ; Not found
    xor eax, eax
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.ga_match:
    lea rdi, [rel sre_pattern_match_method]
    lea rsi, [rel sp_match_str]
    call builtin_func_new
    jmp .ga_bind
.ga_search:
    lea rdi, [rel sre_pattern_search_method]
    lea rsi, [rel sp_search_str]
    call builtin_func_new
    jmp .ga_bind
.ga_fullmatch:
    lea rdi, [rel sre_pattern_fullmatch_method]
    lea rsi, [rel sp_fullmatch_str]
    call builtin_func_new
    jmp .ga_bind
.ga_findall:
    lea rdi, [rel sre_pattern_findall_method]
    lea rsi, [rel sp_findall_str]
    call builtin_func_new
    jmp .ga_bind
.ga_sub:
    lea rdi, [rel sre_pattern_sub_method]
    lea rsi, [rel sp_sub_str]
    call builtin_func_new
    jmp .ga_bind
.ga_subn:
    lea rdi, [rel sre_pattern_subn_method]
    lea rsi, [rel sp_subn_str]
    call builtin_func_new
    jmp .ga_bind
.ga_split:
    lea rdi, [rel sre_pattern_split_method]
    lea rsi, [rel sp_split_str]
    call builtin_func_new
    jmp .ga_bind
.ga_finditer:
    lea rdi, [rel sre_pattern_finditer_method]
    lea rsi, [rel sp_finditer_str]
    call builtin_func_new
    jmp .ga_bind
.ga_scanner:
    lea rdi, [rel sre_pattern_finditer_method]
    lea rsi, [rel sp_scanner_str]
    call builtin_func_new
    jmp .ga_bind
.ga_copy:
    lea rdi, [rel sre_pattern_copy_method]
    lea rsi, [rel sp_copy_str]
    call builtin_func_new
    jmp .ga_bind

.ga_bind:
    ; rax = builtin func from builtin_func_new
    push rax                    ; save func
    mov rdi, rax                ; func
    mov rsi, rbx                ; self (pattern)
    call method_new
    push rax
    mov rdi, [rsp + 8]         ; DECREF unbound func
    call obj_decref
    pop rax
    add rsp, 8
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.ga_pattern_attr:
    ; Return pattern.pattern (the regex string)
    mov rax, [rbx + SRE_PatternObject.pattern]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.ga_flags:
    mov eax, [rbx + SRE_PatternObject.flags]     ; resd 1: 32-bit, zero-extends
    RET_TAG_SMALLINT
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.ga_groups:
    mov eax, [rbx + SRE_PatternObject.groups]
    movsx rax, eax
    RET_TAG_SMALLINT
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.ga_groupindex:
    mov rax, [rbx + SRE_PatternObject.groupindex]
    test rax, rax
    jz .ga_empty_dict
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret
.ga_empty_dict:
    call dict_new
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret
END_FUNC sre_pattern_getattr

;; ============================================================================
;; Helper: strcmp for attribute lookup
;; ============================================================================
DEF_FUNC sre_strcmp
    ; rdi = str1, rsi = str2
.cmp_loop:
    movzx eax, byte [rdi]
    movzx ecx, byte [rsi]
    cmp al, cl
    jne .cmp_ne
    test al, al
    jz .cmp_eq
    inc rdi
    inc rsi
    jmp .cmp_loop
.cmp_eq:
    xor eax, eax
    leave
    ret
.cmp_ne:
    mov eax, 1
    leave
    ret
END_FUNC sre_strcmp

;; ============================================================================
;; sre_pattern_copy_method(self, args, nargs)
;; __copy__ / __deepcopy__ — patterns are effectively immutable.
;; Returns self (INCREF'd).
;; ============================================================================
DEF_FUNC sre_pattern_copy_method
    mov rax, [rdi]             ; self payload
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC sre_pattern_copy_method

;; ============================================================================
;; sre_pattern_hash(PyObject* self) -> i64
;; hash(pattern_str) XOR flags XOR (groups << 16)
;; ============================================================================
extern str_hash

DEF_FUNC sre_pattern_hash, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi               ; self

    ; hash(pattern), through the object's OWN tp_hash.
    ;
    ; This called str_hash whatever `.pattern` held, and str_hash reads a
    ; cached hash from PyStrObject.ob_hash at +24 and writes the one it
    ; computes back there.  PyBytesObject.data starts at +24, so for a BYTES
    ; pattern that read the first eight bytes of the pattern text as a hash --
    ; past the end of the object when the pattern is shorter than that -- and,
    ; when those bytes happened to read as -1, overwrote them with the hash.
    ; `re.compile(re.escape(b"\xff" * 8))` is that case, and it corrupted its
    ; own pattern.
    mov rdi, [rbx + SRE_PatternObject.pattern]
    extern obj_hash
    call obj_hash

    ; XOR flags
    mov ecx, [rbx + SRE_PatternObject.flags]
    movsx rcx, ecx
    xor rax, rcx

    ; XOR (groups << 16)
    mov ecx, [rbx + SRE_PatternObject.groups]
    movsx rcx, ecx
    shl rcx, 16
    xor rax, rcx

    pop rbx
    leave
    ret
END_FUNC sre_pattern_hash

;; ============================================================================
;; sre_pattern_richcompare(rdi=left, rsi=right, edx=op, rcx=left_tag, r8=right_tag)
;;   -> (rax=payload, edx=tag)
;; Supports PY_EQ and PY_NE only. Compares type, flags, groups, pattern string.
;; ============================================================================
extern str_compare

DEF_FUNC sre_pattern_richcompare
    V_UNPACK rdi, rcx           ; left  Value -> (payload, tag)
    V_UNPACK rsi, r8            ; right Value -> (payload, tag)
    push rbx
    push r12
    push r13

    mov rbx, rdi               ; left
    mov r12, rsi               ; right
    mov r13d, edx              ; op

    ; Only support PY_EQ (2) and PY_NE (3)
    cmp r13d, PY_EQ
    je .prc_compare
    cmp r13d, PY_NE
    je .prc_compare

    ; Return NotImplemented → for now return False
    xor eax, eax
    RET_NONE
    jmp .prc_ret

.prc_compare:
    ; Check right is also a Pattern
    cmp r8d, TAG_PTR
    jne .prc_ne_result
    mov rax, [r12 + PyObject.ob_type]
    lea rcx, [rel sre_pattern_type]
    cmp rax, rcx
    jne .prc_ne_result

    ; Compare flags
    mov eax, [rbx + SRE_PatternObject.flags]
    cmp eax, [r12 + SRE_PatternObject.flags]
    jne .prc_ne_result

    ; Compare groups
    mov eax, [rbx + SRE_PatternObject.groups]
    cmp eax, [r12 + SRE_PatternObject.groups]
    jne .prc_ne_result

    ; Compare the pattern texts the ordinary way.  str_compare reads the text
    ; at PyStrObject.data (+40), where a bytes keeps it at +24 -- so two BYTES
    ; patterns compared whatever sat past the end of each and were never
    ; equal.  A str and a bytes are refused above, so this is like against
    ; like; -1 cannot happen for two of either, and is not equal if it does.
    mov rdi, [rbx + SRE_PatternObject.pattern]
    mov rsi, [r12 + SRE_PatternObject.pattern]
    mov edx, PY_EQ
    extern obj_richcompare_bool
    call obj_richcompare_bool
    cmp eax, 1
    jne .prc_ne_result

    ; Patterns are equal
    cmp r13d, PY_EQ
    je .prc_true
    jmp .prc_false

.prc_ne_result:
    ; Patterns are not equal
    cmp r13d, PY_NE
    je .prc_true
    jmp .prc_false

.prc_true:
    mov eax, 1
    RET_BOOL_RAX
    jmp .prc_ret
.prc_false:
    xor eax, eax
    RET_BOOL_RAX
.prc_ret:
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC sre_pattern_richcompare

;; ============================================================================
;; sre_pattern_finditer_method(self, args, nargs)
;; Pattern.finditer(string, pos=0, endpos=sys.maxsize)
;; Returns an SRE_Scanner iterator.
;; ============================================================================
DEF_FUNC sre_pattern_finditer_method, 8            ; 3 pushes, so rsp is 16-aligned
    ; rdi = args (fat array), rsi = nargs
    push rbx
    push r12
    push r13

    mov rbx, [rdi]             ; self = pattern
    lea r12, [rdi + 8]         ; user args
    lea r13, [rsi - 1]         ; user nargs

    test r13, r13
    je .fi_error

    ; string = user_args[0]
    mov rsi, [r12]             ; string payload

    ; pos (default 0)
    xor edx, edx
    cmp r13, 2
    jb .fi_no_pos
    mov rdi, [r12 + 8]
    call sp_arg_i64
    mov rdx, rax               ; pos
.fi_no_pos:

    ; endpos (default large)
    mov rcx, 0x7fffffffffffffff
    cmp r13, 3
    jb .fi_no_endpos
    mov rdi, [r12 + 16]
    call sp_arg_i64
    mov rcx, rax               ; endpos
.fi_no_endpos:

    ; finditer does not build a state -- it builds a scanner and walks it
    ; later -- so it is the one entry point sre_state_init's check does not
    ; cover.  Without this, p.finditer(5) stored the int in the scanner and
    ; the crash arrived somewhere else entirely.
    push rdx
    push rcx
    push rsi
    sub rsp, 8
    mov rdi, [r12]              ; the subject, read from the arguments again
    mov rsi, rbx                ; the pattern, so the kinds are checked
    extern sre_require_subject
    call sre_require_subject
    add rsp, 8
    pop rsi
    pop rcx
    pop rdx

    ; scanner_new(pattern, string, pos, endpos)
    mov rdi, rbx               ; pattern
    ; rsi = string (already set)
    ; rdx = pos
    ; rcx = endpos
    call sre_scanner_new

    mov edx, TAG_PTR

    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.fi_error:
    RAISE exc_TypeError_type, "finditer() requires a string argument"
END_FUNC sre_pattern_finditer_method

;; ============================================================================
;; SRE_Scanner implementation
;; ============================================================================

;; ============================================================================
;; sre_scanner_new(rdi=pattern, rsi=string, rdx=pos, rcx=endpos) -> rax
;; Allocates and initializes an SRE_ScannerObject.
;; ============================================================================
DEF_FUNC sre_scanner_new, 8            ; 5 pushes, so rsp is 16-aligned
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r12, rdi               ; pattern
    mov r13, rsi               ; string
    mov r14, rdx               ; pos
    mov r15, rcx               ; endpos

    mov edi, SRE_ScannerObject_size
    call ap_malloc
    mov rbx, rax

    mov qword [rbx + PyObject.ob_refcnt], 1
    lea rax, [rel sre_scanner_type]
    mov [rbx + PyObject.ob_type], rax

    mov [rbx + SRE_ScannerObject.pattern], r12
    inc qword [r12 + PyObject.ob_refcnt]

    mov [rbx + SRE_ScannerObject.string], r13
    inc qword [r13 + PyObject.ob_refcnt]

    mov [rbx + SRE_ScannerObject.pos], r14
    mov [rbx + SRE_ScannerObject.endpos], r15
    mov qword [rbx + SRE_ScannerObject.must_advance], 0
    ; ap_malloc does not zero, and sre_state_init reads .cp_buf to decide
    ; whether the cache is filled.
    mov qword [rbx + SRE_ScannerObject.cp_buf], 0
    mov qword [rbx + SRE_ScannerObject.cp_len], 0
    mov qword [rbx + SRE_ScannerObject.cp_subject], 0
    mov qword [rbx + SRE_ScannerObject.cp_borrows], 0

    mov rax, rbx

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC sre_scanner_new

;; ============================================================================
;; sre_scanner_dealloc(rdi=self)
;; ============================================================================
DEF_FUNC sre_scanner_dealloc, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi

    mov rdi, [rbx + SRE_ScannerObject.pattern]
    call obj_decref

    mov rdi, [rbx + SRE_ScannerObject.string]
    call obj_decref

    ; The decoded subject, if any state ever handed one over.  Every
    ; SRE_State built from this scanner borrowed it, so this is the only
    ; owner.
    mov rdi, [rbx + SRE_ScannerObject.cp_buf]
    test rdi, rdi
    jz .ssd_no_cache
    call ap_free
.ssd_no_cache:
    ; The cache keeps a reference to the string it decoded, so that the
    ; address it keys on cannot be reused by a different one.
    mov rdi, [rbx + SRE_ScannerObject.cp_subject]
    test rdi, rdi
    jz .ssd_no_subject
    call obj_decref
.ssd_no_subject:

    mov rdi, rbx
    call ap_free

    pop rbx
    leave
    ret
END_FUNC sre_scanner_dealloc

;; ============================================================================
;; sre_scanner_iter_self(rdi=self) -> rax (no edx, tp_iter convention)
;; ============================================================================
DEF_FUNC_BARE sre_scanner_iter_self
    inc qword [rdi + PyObject.ob_refcnt]
    mov rax, rdi
    ret
END_FUNC sre_scanner_iter_self

;; ============================================================================
;; sre_scanner_iternext(rdi=self) -> (rax, edx) fat value
;; Returns next match via sre_search, or NULL on exhaustion.
;; ============================================================================
SI_SELF    equ 8
SI_STATE   equ 8 + SRE_State_size
SI_FRAME   equ 8 + SRE_State_size

DEF_FUNC sre_scanner_iternext, SI_FRAME
    push rbx
    push r12
    push r13

    mov [rbp - SI_SELF], rdi
    mov rbx, rdi

    ; Check if past end
    mov rax, [rbx + SRE_ScannerObject.pos]
    cmp rax, [rbx + SRE_ScannerObject.endpos]
    ja .si_exhausted

    ; Init state
    lea rdi, [rbp - SI_STATE]
    mov rsi, [rbx + SRE_ScannerObject.pattern]
    mov rdx, [rbx + SRE_ScannerObject.string]
    mov rcx, [rbx + SRE_ScannerObject.pos]
    mov r8, [rbx + SRE_ScannerObject.endpos]
    lea r9, [rbx + SRE_ScannerObject.cp_buf]  ; decode cache
    call sre_state_init

    ; Reset state marks
    lea rdi, [rbp - SI_STATE]
    call sre_state_reset_marks
    mov rbx, [rbp - SI_SELF]
    mov rax, [rbx + SRE_ScannerObject.must_advance]
    mov [rdi + SRE_State.must_advance], eax

    ; Search
    lea rdi, [rbp - SI_STATE]
    call sre_search
    test eax, eax
    jz .si_no_match

    ; Get match boundaries
    lea rdi, [rbp - SI_STATE]
    mov r12, [rdi + SRE_State.str_start]   ; match_start
    mov r13, [rdi + SRE_State.str_pos]     ; match_end

    ; Create match object
    lea rdi, [rbp - SI_STATE]
    mov rbx, [rbp - SI_SELF]
    mov rsi, [rbx + SRE_ScannerObject.pattern]
    mov rdx, [rbx + SRE_ScannerObject.string]
    call sre_match_new
    push rax                   ; save match object

    ; Clean up state
    lea rdi, [rbp - SI_STATE]
    call sre_state_fini

    ; Advance the scanner.  An empty match stays put with must_advance set --
    ; see .fa_advance in findall.  The flag lives on the scanner because each
    ; call builds its own state.
    mov rbx, [rbp - SI_SELF]
    mov rax, r13               ; match_end
    mov qword [rbx + SRE_ScannerObject.must_advance], 0
    cmp rax, r12
    jne .si_advance_ok
    mov qword [rbx + SRE_ScannerObject.must_advance], 1
.si_advance_ok:
    mov [rbx + SRE_ScannerObject.pos], rax

    pop rax                    ; match object
    mov edx, TAG_PTR           ; the tag was never set on this path: the
                               ; caller V_PACKs (rax, rdx), so scanner.search()
                               ; handed back whatever edx happened to hold.
                               ; With the ordinary allocator that looked like a
                               ; pointer; under a different heap layout it read
                               ; as TAG_SMALLINT and the match came back as its
                               ; own address.

    pop r13
    pop r12
    pop rbx
    leave
    ret

.si_no_match:
    lea rdi, [rbp - SI_STATE]
    call sre_state_fini
    ; A failed attempt ENDS the scan.  CPython marks it by clearing
    ; state->start, and every later match()/search() on the scanner returns
    ; None from the guard at the top (sre.c, _sre_SRE_Scanner_match_impl).
    ; Here the scan simply carried on from wherever the failed attempt left
    ; the position, so `sc.match(); sc.search()` found the match CPython
    ; does not.  pos is the guard's subject and it is compared UNSIGNED, so
    ; -1 is past every real endpos and needs no second field.
    mov rbx, [rbp - SI_SELF]
    mov qword [rbx + SRE_ScannerObject.pos], -1

.si_exhausted:
    RET_NULL

    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC sre_scanner_iternext

;; ============================================================================
;; sre_scanner_search_method(self, args, nargs)
;; scanner.search() — same as iternext but returns None instead of NULL
;; ============================================================================
DEF_FUNC sre_scanner_search_method
    mov rdi, [rdi]             ; self = args[0] payload
    call sre_scanner_iternext
    ; If NULL (tag=0), return None
    test edx, edx
    jnz .ssm_done
    xor eax, eax
    RET_NONE
.ssm_done:
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC sre_scanner_search_method

;; ============================================================================
;; sre_scanner_match_method(self, args, nargs)
;; scanner.match() — anchored match at current pos, returns match or None
;; ============================================================================
SM2_SELF   equ 8
SM2_STATE  equ 8 + SRE_State_size
SM2_FRAME  equ 8 + SRE_State_size

DEF_FUNC sre_scanner_match_method, SM2_FRAME
    push rbx
    push r12
    push r13

    mov rbx, [rdi]             ; self = args[0] payload
    mov [rbp - SM2_SELF], rbx

    ; Check if past end
    mov rax, [rbx + SRE_ScannerObject.pos]
    cmp rax, [rbx + SRE_ScannerObject.endpos]
    ja .sm2_none

    ; Init state
    lea rdi, [rbp - SM2_STATE]
    mov rsi, [rbx + SRE_ScannerObject.pattern]
    mov rdx, [rbx + SRE_ScannerObject.string]
    mov rcx, [rbx + SRE_ScannerObject.pos]
    mov r8, [rbx + SRE_ScannerObject.endpos]
    lea r9, [rbx + SRE_ScannerObject.cp_buf]  ; decode cache
    call sre_state_init

    ; Reset marks
    lea rdi, [rbp - SM2_STATE]
    call sre_state_reset_marks
    mov rbx, [rbp - SM2_SELF]
    mov rax, [rbx + SRE_ScannerObject.must_advance]
    mov [rdi + SRE_State.must_advance], eax

    ; Anchored match (not search)
    lea rdi, [rbp - SM2_STATE]
    mov rax, [rdi + SRE_State.str_pos]
    mov [rdi + SRE_State.search_origin], rax
    mov rbx, [rbp - SM2_SELF]
    mov rsi, [rbx + SRE_ScannerObject.pattern]
    mov rsi, [rsi + SRE_PatternObject.code]
    mov edx, 1
    call sre_match
    test eax, eax
    jz .sm2_no_match

    ; Get match boundaries
    lea rdi, [rbp - SM2_STATE]
    mov r12, [rdi + SRE_State.str_start]
    mov r13, [rdi + SRE_State.str_pos]

    ; Create match object
    lea rdi, [rbp - SM2_STATE]
    mov rbx, [rbp - SM2_SELF]
    mov rsi, [rbx + SRE_ScannerObject.pattern]
    mov rdx, [rbx + SRE_ScannerObject.string]
    call sre_match_new
    push rax

    lea rdi, [rbp - SM2_STATE]
    call sre_state_fini

    ; Advance scanner pos
    mov rbx, [rbp - SM2_SELF]
    mov rax, r13
    mov qword [rbx + SRE_ScannerObject.must_advance], 0
    cmp rax, r12
    jne .sm2_adv_ok
    mov qword [rbx + SRE_ScannerObject.must_advance], 1
.sm2_adv_ok:
    mov [rbx + SRE_ScannerObject.pos], rax

    pop rax
    mov edx, TAG_PTR

    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.sm2_no_match:
    lea rdi, [rbp - SM2_STATE]
    call sre_state_fini
    ; The scan is over -- see sre_scanner_iternext's .si_no_match.
    mov rbx, [rbp - SM2_SELF]
    mov qword [rbx + SRE_ScannerObject.pos], -1

.sm2_none:
    xor eax, eax
    RET_NONE

    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC sre_scanner_match_method

;; ============================================================================
;; sre_scanner_getattr(rdi=self, rsi=name) -> (rax, edx)
;; ============================================================================
DEF_FUNC sre_scanner_getattr
    push rbx
    push r12

    mov rbx, rdi               ; self
    mov r12, rsi               ; name

    lea rdi, [r12 + PyStrObject.data]
    lea rsi, [rel sc_match_str]
    call sre_strcmp
    test eax, eax
    jz .sga_match

    lea rdi, [r12 + PyStrObject.data]
    lea rsi, [rel sc_search_str]
    call sre_strcmp
    test eax, eax
    jz .sga_search

    lea rdi, [r12 + PyStrObject.data]
    lea rsi, [rel sp_pattern_str]
    call sre_strcmp
    test eax, eax
    jz .sga_pattern

    ; Not found
    xor eax, eax
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.sga_match:
    lea rdi, [rel sre_scanner_match_method]
    lea rsi, [rel sc_match_str]
    call builtin_func_new
    jmp .sga_bind
.sga_search:
    lea rdi, [rel sre_scanner_search_method]
    lea rsi, [rel sc_search_str]
    call builtin_func_new
    jmp .sga_bind

.sga_bind:
    push rax
    mov rdi, rax
    mov rsi, rbx
    call method_new
    push rax
    mov rdi, [rsp + 8]
    call obj_decref
    pop rax
    add rsp, 8
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.sga_pattern:
    mov rax, [rbx + SRE_ScannerObject.pattern]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret
END_FUNC sre_scanner_getattr

;; ============================================================================
;; Type definitions
;; ============================================================================
section .data
align 8

; SRE_Scanner type
global sre_scanner_type
sre_scanner_type:
    dq 1                       ; ob_refcnt (immortal)
    dq type_type               ; ob_type
    dq sc_type_name            ; tp_name
    dq SRE_ScannerObject_size  ; tp_basicsize
    dq sre_scanner_dealloc     ; tp_dealloc
    dq 0                       ; tp_repr
    dq 0                       ; tp_str
    dq 0                       ; tp_hash
    dq 0                       ; tp_call
    dq sre_scanner_getattr     ; tp_getattr
    dq 0                       ; tp_setattr
    dq 0                       ; tp_richcompare
    dq sre_scanner_iter_self   ; tp_iter
    dq sre_scanner_iternext    ; tp_iternext
    dq 0                       ; tp_init
    dq 0                       ; tp_new
    dq 0                       ; tp_as_number
    dq 0                       ; tp_as_sequence
    dq 0                       ; tp_as_mapping
    dq 0                       ; tp_base
    dq 0                       ; tp_dict
    dq 0                       ; tp_mro
    dq 0                       ; tp_flags
    dq 0                       ; tp_bases
    dq 0                        ; tp_traverse
    dq 0                        ; tp_clear
    dq 0 ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

align 8

; SRE_Pattern type
global sre_pattern_type
sre_pattern_type:
    dq 1                       ; ob_refcnt (immortal)
    dq type_type               ; ob_type
    dq sp_type_name            ; tp_name
    dq SRE_PatternObject_size  ; tp_basicsize
    dq sre_pattern_dealloc     ; tp_dealloc
    dq sre_pattern_repr        ; tp_repr
    dq sre_pattern_repr        ; tp_str
    dq sre_pattern_hash        ; tp_hash
    dq 0                       ; tp_call (patterns aren't directly callable)
    dq sre_pattern_getattr     ; tp_getattr
    dq 0                       ; tp_setattr
    dq sre_pattern_richcompare ; tp_richcompare
    dq 0                       ; tp_iter
    dq 0                       ; tp_iternext
    dq 0                       ; tp_init
    dq 0                       ; tp_new
    dq 0                       ; tp_as_number
    dq 0                       ; tp_as_sequence
    dq 0                       ; tp_as_mapping
    dq 0                       ; tp_base
    dq 0                       ; tp_dict
    dq 0                       ; tp_mro
    dq 0                       ; tp_flags
    dq 0                       ; tp_bases
    dq 0                        ; tp_traverse
    dq 0                        ; tp_clear
    dq 0 ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

section .rodata
sp_type_name:     db "re.Pattern", 0
sp_join_item:      db "sequence item ", 0
sp_join_want_str:  db ": expected str instance, bytes found", 0
sp_join_want_bytes: db ": expected a bytes-like object, str found", 0
sp_match_str:     db "match", 0
sp_search_str:    db "search", 0
sp_fullmatch_str: db "fullmatch", 0
sp_findall_str:   db "findall", 0
sp_finditer_str:  db "finditer", 0
sp_sub_str:       db "sub", 0
sp_subn_str:      db "subn", 0
sp_split_str:     db "split", 0
sp_pattern_str:   db "pattern", 0
sp_flags_str:     db "flags", 0
sp_groups_str:    db "groups", 0
sp_groupindex_str: db "groupindex", 0
sp_scanner_str:    db "scanner", 0
sp_copy_str:       db "__copy__", 0
sp_deepcopy_str:   db "__deepcopy__", 0

; Scanner type rodata
sc_type_name:      db "re.Scanner", 0
sc_match_str:      db "match", 0
sc_search_str:     db "search", 0
