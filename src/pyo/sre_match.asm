; sre_match.asm - SRE_Match type implementation
; Provides group/groups/groupdict/start/end/span methods and
; re/string/pos/endpos/lastindex/lastgroup/regs attributes.

%include "macros.inc"
%include "object.inc"
%include "sre.inc"

extern dict_get
extern dict_set
extern set_exception
extern ap_malloc
extern ap_free
extern ap_memcpy
extern obj_decref
extern obj_incref
extern obj_dealloc
extern str_from_cstr_heap
extern str_new_heap
extern dict_new
extern tuple_new
extern none_singleton
extern exc_TypeError_type
extern exc_IndexError_type
extern str_type
extern type_type
extern builtin_func_new
extern sre_utf8_codepoint_to_byte
extern method_new
extern sre_strcmp

;; ============================================================================
;; sre_match_new(SRE_State* state, SRE_PatternObject* pattern,
;;               PyStrObject* string) -> SRE_MatchObject*
;; Create a match object from a successful match state.
;; ============================================================================
MN_STATE    equ 8
MN_PAT      equ 16
MN_STR      equ 24
MN_FRAME    equ 24          ; + 3 pushes = 48

DEF_FUNC sre_match_new, MN_FRAME
    push rbx
    push r12
    push r13

    mov [rbp - MN_STATE], rdi
    mov [rbp - MN_PAT], rsi
    mov [rbp - MN_STR], rdx

    ; Calculate marks count (groups * 2 + 2 for group 0)
    mov eax, [rsi + SRE_PatternObject.groups]
    lea ecx, [eax + 1]
    shl ecx, 1                 ; marks_count = (groups + 1) * 2
    mov r12d, ecx              ; r12 = marks count

    ; Allocate match object: base size + marks array
    lea edi, [r12*8]
    add edi, SRE_MatchObject_size
    call ap_malloc
    mov rbx, rax               ; rbx = match object

    ; Initialize header
    INIT_OBJ_RC rbx
    lea rax, [rel sre_match_type]
    mov [rbx + PyObject.ob_type], rax

    ; Set fields
    mov rax, [rbp - MN_PAT]
    mov [rbx + SRE_MatchObject.pattern], rax
    INCREF rax

    mov rax, [rbp - MN_STR]
    mov [rbx + SRE_MatchObject.string], rax
    INCREF rax

    mov rdi, [rbp - MN_STATE]
    mov rax, [rdi + SRE_State.str_begin]
    mov [rbx + SRE_MatchObject.str_begin], rax

    ; pos = original_pos (the pos argument passed to match/search)
    mov rax, [rdi + SRE_State.original_pos]
    mov [rbx + SRE_MatchObject.pos], rax

    ; endpos
    mov rdi, [rbp - MN_STATE]
    mov rax, [rdi + SRE_State.codepoint_buf]
    test rax, rax
    jnz .mn_unicode_endpos
    mov rax, [rdi + SRE_State.str_end]
    sub rax, [rdi + SRE_State.str_begin]
    jmp .mn_set_endpos
.mn_unicode_endpos:
    mov rax, [rdi + SRE_State.codepoint_len]
.mn_set_endpos:
    mov [rbx + SRE_MatchObject.endpos], rax

    ; lastindex
    mov rdi, [rbp - MN_STATE]
    mov rax, [rdi + SRE_State.lastindex]
    mov [rbx + SRE_MatchObject.lastindex], rax

    ; lastgroup: look up indexgroup[lastindex] if available
    mov qword [rbx + SRE_MatchObject.lastgroup], 0
    mov rax, [rbp - MN_STATE]
    mov rcx, [rax + SRE_State.lastindex]
    test rcx, rcx
    jle .mn_no_lastgroup
    ; Check if pattern has indexgroup tuple
    mov rax, [rbp - MN_PAT]
    mov rax, [rax + SRE_PatternObject.indexgroup]
    test rax, rax
    jz .mn_no_lastgroup
    ; Bounds check: lastindex < tuple.ob_size
    cmp rcx, [rax + PyVarObject.ob_size]
    jge .mn_no_lastgroup
    ; indexgroup tuple: payloads/tags arrays
    mov r8, [rax + PyTupleObject.ob_item]
    mov rax, [r8 + rcx*8]
    V_TEST_PTR rax, rdx
    ja .mn_no_lastgroup         ; None or non-string → NULL
    INCREF rax
    mov [rbx + SRE_MatchObject.lastgroup], rax
.mn_no_lastgroup:

    ; marks_count
    mov [rbx + SRE_MatchObject.marks_count], r12

    ; Copy marks: group 0 = (str_start, str_pos), then from state marks
    mov rdi, [rbp - MN_STATE]

    ; Mark 0 = match start position
    mov rax, [rdi + SRE_State.str_start]
    lea rcx, [rbx + SRE_MatchObject.marks]
    mov [rcx], rax

    ; Mark 1 = match end position
    mov rax, [rdi + SRE_State.str_pos]
    mov [rcx + 8], rax

    ; Copy state marks to match.marks[2..] (group 1+ data)
    ; State marks[0] = MARK 0 from bytecode = group 1 start
    ; State marks[1] = MARK 1 from bytecode = group 1 end
    ; etc. These go into match.marks[2..] (after group 0 pair)
    mov r13, [rdi + SRE_State.marks_size]
    test r13, r13
    je .mn_no_marks

    ; Source: state marks from index 0
    mov rsi, [rdi + SRE_State.marks]
    lea rdi, [rcx + 16]       ; destination: after group 0 marks

    ; Count: min(state.marks_size, r12 - 2)
    mov rcx, r12
    sub rcx, 2
    cmp r13, rcx
    jle .mn_use_state_count
    mov r13, rcx
.mn_use_state_count:
    test r13, r13
    jle .mn_no_marks
    shl r13, 3                 ; bytes
    mov rdx, r13
    call ap_memcpy

    ; Initialize any remaining marks to -1
    jmp .mn_init_remaining

.mn_no_marks:
    ; Initialize all marks after group 0 to -1
    lea rdi, [rbx + SRE_MatchObject.marks + 16]
    mov rcx, r12
    sub rcx, 2
    test rcx, rcx
    jle .mn_done
.mn_fill_neg1:
    mov qword [rdi], -1
    add rdi, 8
    dec rcx
    jnz .mn_fill_neg1
    jmp .mn_done

.mn_init_remaining:
    ; Fill remaining marks (beyond what was copied) with -1
    ; r13 = bytes copied, r12 = total marks_count
    lea rdi, [rbx + SRE_MatchObject.marks + 16]
    add rdi, r13               ; past copied marks
    mov rcx, r12
    sub rcx, 2
    shl rcx, 3                ; total needed bytes
    sub rcx, r13              ; remaining bytes
    shr rcx, 3                ; remaining entries
    test rcx, rcx
    jle .mn_done
.mn_fill_remaining:
    mov qword [rdi], -1
    add rdi, 8
    dec rcx
    jnz .mn_fill_remaining
.mn_done:
    mov rax, rbx
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC sre_match_new

;; ============================================================================
;; sre_match_dealloc(PyObject* self)
;; ============================================================================
DEF_FUNC sre_match_dealloc, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi

    mov rdi, [rbx + SRE_MatchObject.pattern]
    test rdi, rdi
    jz .no_pat
    call obj_decref
.no_pat:

    mov rdi, [rbx + SRE_MatchObject.string]
    test rdi, rdi
    jz .no_str
    call obj_decref
.no_str:

    mov rdi, [rbx + SRE_MatchObject.lastgroup]
    test rdi, rdi
    jz .no_lg
    call obj_decref
.no_lg:

    mov rdi, rbx
    call ap_free

    pop rbx
    leave
    ret
END_FUNC sre_match_dealloc

;; ============================================================================
;; sre_match_repr(PyObject* self) -> PyObject*
;;
;; "<re.Match object; span=(1, 2), match='b'>".  It used to say "<re.Match
;; object>" and nothing else, so any test that prints a match diverged for a
;; reason that had nothing to do with the match.
;;
;; CPython's format string is "%.50R" for the matched text, which truncates
;; the REPR to fifty code points and does not mark that it did -- a long
;; match loses its closing quote, and that is the answer to reproduce.
;; ============================================================================
MRP_SELF equ 8
MRP_TEXT equ 16         ; the group-0 string
MRP_REPR equ 24         ; and its repr
MRP_END  equ 32         ; where the next byte goes
MRP_BUF  equ 416        ; 384 bytes: the fixed parts, two numbers, 50 points
MRP_FRAME equ 432           ; + 0 pushes = 432, 16-aligned
DEF_FUNC sre_match_repr, MRP_FRAME
    mov [rbp - MRP_SELF], rdi
    mov qword [rbp - MRP_TEXT], 0
    mov qword [rbp - MRP_REPR], 0

    lea rdi, [rbp - MRP_BUF]
    CSTRING rsi, "<re.Match object; span=("
    extern rbt_append_cstr
    call rbt_append_cstr
    mov rdi, rax
    mov rcx, [rbp - MRP_SELF]
    mov rsi, [rcx + SRE_MatchObject.marks]
    extern msg_append_i64
    call msg_append_i64
    mov rdi, rax
    CSTRING rsi, ", "
    call rbt_append_cstr
    mov rdi, rax
    mov rcx, [rbp - MRP_SELF]
    mov rsi, [rcx + SRE_MatchObject.marks + 8]
    call msg_append_i64
    mov rdi, rax
    CSTRING rsi, "), match="
    call rbt_append_cstr
    mov [rbp - MRP_END], rax

    ; The matched text, through the same accessor group(0) uses -- which is
    ; what makes a bytes subject answer b'...' rather than a decoded str.
    mov rdi, [rbp - MRP_SELF]
    xor esi, esi
    call sre_match_get_group_str    ; err: group 0 always exists
    test edx, edx
    jz .mrp_no_text
    cmp edx, TAG_PTR
    jne .mrp_no_text
    mov [rbp - MRP_TEXT], rax
    mov rdi, rax
    extern obj_repr
    call obj_repr
    test rax, rax
    jz .mrp_no_text
    mov [rbp - MRP_REPR], rax

    ; Fifty CODE POINTS of it, which for anything non-ASCII is more bytes.
    mov rcx, [rax + PyStrObject.ob_length]
    cmp rcx, 50
    jbe .mrp_whole
    mov rdi, rax
    mov esi, 50
    extern str_cp_offset
    call str_cp_offset
    mov rdx, rax
    jmp .mrp_copy
.mrp_whole:
    mov rdx, [rax + PyStrObject.ob_size]
.mrp_copy:
    mov rsi, [rbp - MRP_REPR]
    lea rsi, [rsi + PyStrObject.data]
    mov rdi, [rbp - MRP_END]
    add [rbp - MRP_END], rdx
    extern ap_memcpy
    call ap_memcpy

.mrp_no_text:
    mov rdi, [rbp - MRP_END]
    CSTRING rsi, ">"
    call rbt_append_cstr

    lea rdi, [rbp - MRP_BUF]
    call str_from_cstr_heap
    mov [rbp - MRP_END], rax
    mov rdi, [rbp - MRP_REPR]
    test rdi, rdi
    jz .mrp_no_repr
    call obj_decref
.mrp_no_repr:
    mov rdi, [rbp - MRP_TEXT]
    test rdi, rdi
    jz .mrp_done
    call obj_decref
.mrp_done:
    mov rax, [rbp - MRP_END]
    mov edx, TAG_PTR
    leave
    ret
END_FUNC sre_match_repr

;; ============================================================================
;; sre_match_bool(PyObject* self) -> i64 (0 or 1)
;; Match objects are always truthy.
;; ============================================================================
DEF_FUNC_BARE sre_match_bool
    mov eax, 1
    ret
END_FUNC sre_match_bool

;; ============================================================================
;; match_data_base(rdi = the match) -> rax = the subject's data, rdx = its
;; length in bytes
;;
;; str_begin is cached at match time and a MUTABLE subject moves: a bytearray
;; that is cleared and refilled leaves the match pointing into freed memory.
;; The subject itself is held by the match, so the pointer is taken from it
;; here, every time.
;; ============================================================================
DEF_FUNC_LOCAL match_data_base
    mov rax, [rdi + SRE_MatchObject.string]
    test rax, rax
    jz .mdb_cached
    push rdi
    sub rsp, 8
    mov rdi, rax
    extern bytes_like_ptr_len
    call bytes_like_ptr_len     ; rax = data, r10 = length, ecx = 1
    add rsp, 8
    pop rdi
    test ecx, ecx
    jz .mdb_str
    mov rdx, r10
    leave
    ret
.mdb_str:
    ; A str: its data is inline and cannot move.
    mov rax, [rdi + SRE_MatchObject.string]
    mov rdx, [rax + PyStrObject.ob_size]
    add rax, PyStrObject.data
    leave
    ret
.mdb_cached:
    mov rax, [rdi + SRE_MatchObject.str_begin]
    xor edx, edx
    leave
    ret
END_FUNC match_data_base

;; ============================================================================
;; Helper: get substring for a group index
;; sre_match_get_group_str(SRE_MatchObject* self, i64 group_idx) -> (rax, edx)
;; Fails: 0
;; Returns string for the group, or None if unmatched.  The one failure is an
;; index the pattern has no group for: IndexError, and (0, 0).
;; ============================================================================
DEF_FUNC sre_match_get_group_str
    push rbx
    push r12
    push r13
    push r14
    mov rbx, rdi               ; self

    ; Validate group index
    mov rax, [rbx + SRE_MatchObject.pattern]
    mov ecx, [rax + SRE_PatternObject.groups]
    inc ecx                     ; groups + 1 (includes group 0)
    cmp rsi, rcx
    jae .group_out_of_range

    ; Get marks for this group
    shl rsi, 1                  ; mark_start = group * 2
    lea rax, [rbx + SRE_MatchObject.marks]
    mov r12, [rax + rsi*8]     ; start pos (codepoint index)
    mov r13, [rax + rsi*8 + 8] ; end pos (codepoint index)

    cmp r12, -1
    je .group_none
    cmp r13, -1
    je .group_none

    ; A BYTES subject is byte-indexed, so it takes the ASCII path whatever
    ; the values are, and answers bytes.
    mov rax, [rbx + SRE_MatchObject.pattern]
    mov r14, [rax + SRE_PatternObject.is_bytes]
    test r14, r14
    jnz .group_ascii

    ; ASCII or not?  ob_size counts bytes and ob_length code points, and they
    ; are equal exactly when every byte is below 0x80 -- the same O(1) question
    ; sre_state_init asks.  This used to scan the entire subject here too, on
    ; every m.group(n), so an incremental parser paid for the whole string
    ; twice per token.
    mov rdi, [rbx + SRE_MatchObject.string]
    mov rax, [rdi + PyStrObject.ob_size]
    cmp rax, [rdi + PyStrObject.ob_length]
    jne .group_unicode

.group_ascii:
    ; ASCII mode: byte index = codepoint index.
    ;
    ; The data pointer is re-derived from the subject rather than taken from
    ; the cached str_begin: a bytearray subject reallocates when it is
    ; resized and the match outlives that, so `m = re.search(b'w(or)ld', ba)`
    ; followed by `ba.clear()` read freed memory.  CPython answers from the
    ; live buffer at the saved offsets, which is what this now does.
    mov rdi, rbx
    call match_data_base        ; rax = data, rdx = length
    mov rdi, rax
    add rdi, r12
    mov rsi, r13
    sub rsi, r12
    mov rax, [rbx + SRE_MatchObject.pattern]
    mov edx, [rax + SRE_PatternObject.is_bytes]
    extern sre_new_slice
    call sre_new_slice
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.group_unicode:
    ; Unicode mode: use shared UTF-8 walker to find byte offsets
    mov rax, [rbx + SRE_MatchObject.string]
    mov rsi, [rax + PyStrObject.ob_size]   ; total byte length
    lea rdi, [rax + PyStrObject.data]

    ; Find byte offset for start codepoint index (r12)
    mov rdx, r12               ; target = start codepoint idx
    xor ecx, ecx               ; start_byte = 0
    xor r8d, r8d               ; start_cp = 0
    push rdi                   ; save str ptr
    push rsi                   ; save byte len
    call sre_utf8_codepoint_to_byte
    mov r14, rax               ; r14 = start byte offset

    ; Find byte offset for end codepoint index (r13)
    pop rsi                    ; restore byte len
    pop rdi                    ; restore str ptr
    mov rdx, r13               ; target = end codepoint idx
    mov rcx, r14               ; start_byte = start offset
    mov r8, r12                ; start_cp = start idx
    call sre_utf8_codepoint_to_byte
    ; rax = end byte offset, r14 = start byte offset

    ; Create substring from byte offsets, from the live data -- see the note
    ; at .group_ascii.
    push rax
    sub rsp, 8
    mov rdi, rbx
    call match_data_base
    add rsp, 8
    mov rdi, rax
    pop rax
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

.group_none:
    xor eax, eax
    RET_NONE
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.group_out_of_range:
    SET_EXC exc_IndexError_type, "no such group"
    RET_NULL
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC sre_match_get_group_str

;; ============================================================================
;; sre_match_resolve_group_idx(rdi=self, rsi=payload, edx=tag)
;;   -> rsi = int_idx, rax = 0
;; Fails: -1
;; Resolve a group argument: SmallInt passes through, string does dict lookup.
;; No such group is IndexError.
;; ============================================================================
DEF_FUNC sre_match_resolve_group_idx
    ; SmallInt → return as-is
    cmp edx, TAG_SMALLINT
    je .rgi_done

    ; TAG_PTR (string) → look up in pattern->groupindex
    test edx, TAG_RC_BIT
    jz .rgi_type_error

    push rdi                    ; save self
    mov rdi, [rdi + SRE_MatchObject.pattern]
    mov rdi, [rdi + SRE_PatternObject.groupindex]
    test rdi, rdi
    jz .rgi_no_group_pop

    ; dict_get(groupindex, key, key_tag)
    ; rsi = key (already set), edx = TAG_PTR
    call dict_get       ; err: tested at .rgi_miss
    V_UNPACK rax, rdx           ; dict_get returns a Value
    ; rax = val payload, edx = val tag
    test edx, edx               ; the tag, not the payload: a hit may be int 0
    jz .rgi_miss
    ; group_idx = val payload (SmallInt)
    mov rsi, rax
    pop rdi                     ; restore self (discard)
.rgi_done:
    xor eax, eax
    leave
    ret

.rgi_no_group_pop:
.rgi_no_group_pop2:             ; self is still pushed; leave drops it
.rgi_type_error:
    SET_EXC exc_IndexError_type, "no such group"
    mov rax, -1
    leave
    ret
.rgi_miss:
    ; No such name -- or the key could not be hashed or compared, and that
    ; error is the answer: m[[]] is a TypeError, as CPython's is.
    cmp qword [gs:ThreadState.current_exception], 0
    je .rgi_no_group_pop2
    mov rax, -1
    leave
    ret
END_FUNC sre_match_resolve_group_idx

;; ============================================================================
;; sre_match_group_method(self, args, nargs)
;; group(*args) — return one or more subgroups of the match.
;; group() or group(0) returns entire match.
;; group(n) returns nth group.
;; group(a, b, ...) returns tuple.
;; ============================================================================
MG_BASE  equ 32             ; rsp after the prologue: 8 + 3 pushes
MG_TUPLE equ 40             ; the result tuple of the several-group form
DEF_FUNC sre_match_group_method, 8            ; 3 pushes, so rsp is 16-aligned
    ; rdi = args (fat array), rsi = nargs
    push rbx
    push r12
    push r13

    mov rbx, [rdi]             ; self = args[0] payload
    lea r12, [rdi + 8]         ; user args start at args[1]
    lea r13, [rsi - 1]         ; user nargs

    ; No args: return group(0)
    test r13, r13
    jz .group_zero

    ; One arg: return single group
    cmp r13, 1
    je .group_single

    ; Multiple args: return tuple
    mov edi, r13d
    call tuple_new
    push rax                   ; save tuple

    xor ecx, ecx               ; index
.group_multi_loop:
    cmp rcx, r13
    jge .group_multi_done
    push rcx
    push r13
    ; Get group index from args (may be string or int)
    mov rax, rcx
    shl rax, 3                 ; one Value per slot
    mov rsi, [r12 + rax]       ; group arg Value
    V_UNPACK rsi, rdx
    mov rdi, rbx
    call sre_match_resolve_group_idx
    ERR_M1 .group_fail_tuple
    ; rsi = resolved int index
    mov rdi, rbx
    call sre_match_get_group_str
    ERR_NULL .group_fail_tuple
    ; rax = payload, edx = tag
    pop r13
    pop rcx
    ; Set in tuple: tuple.ob_item[ecx] = (rax, edx)
    mov rdi, [rsp]             ; tuple (on stack from push before loop)
    ; INCREF if needed
    ; No INCREF: get_group_str hands over a reference of its own, and the
    ; tuple slot takes it.  One taken on top leaked every group asked for.
    ; Write payload and tag
    mov rsi, [rdi + PyTupleObject.ob_item]       ; payloads
    V_PACK rax, rdx
    mov [rsi + rcx * 8], rax
    inc rcx
    jmp .group_multi_loop

.group_multi_done:
    pop rax                    ; tuple
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.group_zero:
    mov rdi, rbx
    xor esi, esi               ; group 0
    call sre_match_get_group_str    ; err: group 0 always exists
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.group_single:
    mov rsi, [r12]             ; group arg Value
    V_UNPACK rsi, rdx
    mov rdi, rbx
    call sre_match_resolve_group_idx
    ERR_M1 .group_fail
    ; rsi = resolved int index
    mov rdi, rbx
    call sre_match_get_group_str    ; err: its (0, 0) is this method's own
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.group_fail_tuple:
    ; The tuple being filled is this frame's, pushed just below the saved
    ; registers; the slots not reached yet are zero.
    mov rdi, [rbp - MG_TUPLE]
    lea rsp, [rbp - MG_BASE]
    call obj_decref
.group_fail:
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC sre_match_group_method

;; ============================================================================
;; sre_match_groups_method(self, args, nargs)
;; groups(default=None) — return all groups as a tuple.
;; ============================================================================
GS_DEFAULT     equ 8
GS_DEFAULT_TAG equ 16
GS_FRAME       equ 24            ; + 5 pushes = 64, 16-aligned

DEF_FUNC sre_match_groups_method, GS_FRAME
    ; rdi = args (fat array), rsi = nargs
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rbx, [rdi]             ; self = args[0] payload
    lea r12, [rdi + 8]         ; user args
    lea r13, [rsi - 1]         ; user nargs

    ; default arg (default = None)
    xor eax, eax
    RET_NONE
    cmp r13, 1
    jb .groups_no_default
    mov rax, [r12]             ; default Value
    V_UNPACK rax, rdx
.groups_no_default:
    mov [rbp - GS_DEFAULT], rax
    mov [rbp - GS_DEFAULT_TAG], rdx

    ; Get number of groups
    mov rax, [rbx + SRE_MatchObject.pattern]
    mov ecx, [rax + SRE_PatternObject.groups]
    test ecx, ecx
    jz .groups_empty

    ; Create tuple of size = groups
    mov edi, ecx
    push rcx
    call tuple_new
    pop rcx
    push rax                   ; save tuple

    ; Fill groups 1..groups
    mov r14d, ecx              ; total groups
    mov ecx, 1                 ; start from group 1
.groups_loop:
    cmp ecx, r14d
    ja .groups_done
    push rcx
    mov rdi, rbx
    mov rsi, rcx
    call sre_match_get_group_str    ; err: 1..groups, all in range
    ; If None and default was given, substitute default
    IS_NONE rax, rcx
    jne .groups_use_val
    ; Use default instead of None (borrowed ref, needs INCREF for tuple)
    mov rax, [rbp - GS_DEFAULT]
    mov edx, [rbp - GS_DEFAULT_TAG]
    INCREF_VAL rax, rdx
.groups_use_val:
    pop rcx
    push rcx
    ; Inline tuple_set: tuple.ob_item[group-1] = (rax, edx)
    ; Fresh strings from sre_match_get_group_str have refcount=1;
    ; tuple takes ownership without INCREF
    mov rdi, [rsp + 8]        ; tuple
    lea esi, [ecx - 1]        ; tuple index = group - 1
    movsx rsi, esi
    mov r8, [rdi + PyTupleObject.ob_item]       ; payloads
    V_PACK rax, rdx
    mov [r8 + rsi * 8], rax
    pop rcx
    inc ecx
    jmp .groups_loop

.groups_done:
    pop rax                    ; tuple
    mov edx, TAG_PTR
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.groups_empty:
    ; Return empty tuple
    xor edi, edi
    call tuple_new
    mov edx, TAG_PTR
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC sre_match_groups_method

;; ============================================================================
;; sre_match_start_method(self, args, nargs)
;; start(group=0)
;; ============================================================================
DEF_FUNC sre_match_start_method, 8            ; 1 pushes, so rsp is 16-aligned
    ; rdi = args (fat array), rsi = nargs
    push rbx
    mov rbx, [rdi]             ; self = args[0] payload
    lea rcx, [rdi + 8]         ; user args
    lea rdx, [rsi - 1]         ; user nargs

    ; Get group index (default 0)
    xor esi, esi               ; default group = 0
    test rdx, rdx
    jz .start_default
    mov rsi, [rcx]             ; group arg Value
    V_UNPACK rsi, rdx
    mov rdi, rbx
    call sre_match_resolve_group_idx
    ERR_M1 .start_fail
    ; rsi = resolved int index
    jmp .start_resolved
.start_default:
.start_resolved:

    ; Get mark for group start
    shl rsi, 1                 ; mark_index = group * 2
    lea rax, [rbx + SRE_MatchObject.marks]

    ; Bounds check
    cmp rsi, [rbx + SRE_MatchObject.marks_count]
    jae .start_error

    mov rax, [rax + rsi*8]
    RET_TAG_SMALLINT

    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.start_error:
    SET_EXC exc_IndexError_type, "no such group"
.start_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC sre_match_start_method

;; ============================================================================
;; sre_match_end_method(self, args, nargs)
;; end(group=0)
;; ============================================================================
DEF_FUNC sre_match_end_method, 8            ; 1 pushes, so rsp is 16-aligned
    ; rdi = args (fat array), rsi = nargs
    push rbx
    mov rbx, [rdi]             ; self = args[0] payload
    lea rcx, [rdi + 8]         ; user args
    lea rdx, [rsi - 1]         ; user nargs

    ; Get group index (default 0)
    xor esi, esi               ; default group = 0
    test rdx, rdx
    jz .end_default
    mov rsi, [rcx]             ; group arg Value
    V_UNPACK rsi, rdx
    mov rdi, rbx
    call sre_match_resolve_group_idx
    ERR_M1 .end_fail
    ; rsi = resolved int index
    jmp .end_resolved
.end_default:
.end_resolved:

    shl rsi, 1
    inc rsi                     ; mark_index = group * 2 + 1
    lea rax, [rbx + SRE_MatchObject.marks]

    cmp rsi, [rbx + SRE_MatchObject.marks_count]
    jae .end_error

    mov rax, [rax + rsi*8]
    RET_TAG_SMALLINT

    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.end_error:
    SET_EXC exc_IndexError_type, "no such group"
.end_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC sre_match_end_method

;; ============================================================================
;; sre_match_span_method(self, args, nargs)
;; span(group=0) -> (start, end) tuple
;; ============================================================================
DEF_FUNC sre_match_span_method
    ; rdi = args (fat array), rsi = nargs
    push rbx
    push r12
    mov rbx, [rdi]             ; self = args[0] payload
    lea rcx, [rdi + 8]         ; user args
    lea rdx, [rsi - 1]         ; user nargs

    xor r12d, r12d             ; group = 0
    test rdx, rdx
    jz .span_default
    mov rsi, [rcx]             ; group arg Value
    V_UNPACK rsi, rdx
    mov rdi, rbx
    call sre_match_resolve_group_idx
    ERR_M1 .span_fail
    mov r12, rsi               ; resolved int index
.span_default:

    ; Get start and end
    mov rcx, r12
    shl rcx, 1
    lea rax, [rbx + SRE_MatchObject.marks]

    ; Bounds check
    lea rdx, [rcx + 1]
    cmp rdx, [rbx + SRE_MatchObject.marks_count]
    jae .span_error

    mov r8, [rax + rcx*8]      ; start
    mov r9, [rax + rcx*8 + 8]  ; end

    ; Save mark values across tuple_new call (clobbers caller-saved regs)
    push r8
    push r9

    ; Create tuple
    mov edi, 2
    call tuple_new

    pop r9
    pop r8

    mov r10, [rax + PyTupleObject.ob_item]
    V_PACK_I64 r8, r11
    mov [r10], r8
    V_PACK_I64 r9, r11
    mov [r10 + 8], r9
    mov edx, TAG_PTR

    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.span_error:
    SET_EXC exc_IndexError_type, "no such group"
.span_fail:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
END_FUNC sre_match_span_method

;; ============================================================================
;; sre_match_groupdict_method(self, args, nargs)
;; groupdict(default=None) -> dict of named groups
;; ============================================================================
GD_SELF        equ 8
GD_RESULT      equ 16
GD_ENTRIES     equ 24
GD_IDX         equ 32
GD_CAP         equ 40
GD_DEFAULT     equ 48
GD_DEFAULT_TAG equ 56
GD_FRAME       equ 64            ; + 4 pushes = 96, 16-aligned

DEF_FUNC sre_match_groupdict_method, GD_FRAME
    ; rdi = args (fat array), rsi = nargs
    push rbx
    push r12
    push r13
    push r14

    mov rax, [rdi]             ; self = args[0] payload
    mov [rbp - GD_SELF], rax

    ; default arg (default = None)
    LOAD_NONE rcx
    mov r8d, TAG_PTR
    lea rdx, [rsi - 1]        ; user nargs
    cmp rdx, 1
    jb .gd_no_default
    mov rcx, [rdi + 8]       ; default payload
    V_UNPACK rcx, r8       ; args[1]
.gd_no_default:
    mov [rbp - GD_DEFAULT], rcx
    mov [rbp - GD_DEFAULT_TAG], r8

    ; Create result dict
    call dict_new
    mov [rbp - GD_RESULT], rax

    ; Get pattern's groupindex dict
    mov rax, [rbp - GD_SELF]
    mov rax, [rax + SRE_MatchObject.pattern]
    mov rcx, [rax + SRE_PatternObject.groupindex]
    test rcx, rcx
    jz .gd_done

    ; Iterate groupindex entries
    mov rax, [rcx + PyDictObject.entries]
    mov [rbp - GD_ENTRIES], rax
    mov rax, [rcx + PyDictObject.capacity]
    mov [rbp - GD_CAP], rax
    mov qword [rbp - GD_IDX], 0

.gd_loop:
    mov rax, [rbp - GD_IDX]
    cmp rax, [rbp - GD_CAP]
    jge .gd_done

    ; entry = entries + idx * DICT_ENTRY_SIZE
    mov rcx, [rbp - GD_ENTRIES]
    imul rax, DICT_ENTRY_SIZE
    lea r12, [rcx + rax]       ; r12 = entry ptr

    ; Skip empty and tombstoned entries
    ENTRY_CLASSIFY r12, .gd_next, .gd_next

    mov r13, [r12 + DictEntry.key]       ; name Value
    V_UNPACK r13, r14                    ; -> (payload, tag)

    ; group_idx = entry->value, an integer Value
    mov rsi, [r12 + DictEntry.value]
    V_UNPACK rsi, rax

    ; sre_match_get_group_str(self, group_idx)
    mov rdi, [rbp - GD_SELF]
    call sre_match_get_group_str    ; err: groupindex names only real groups
    ; rax = val payload, edx = val tag
    ; If None, substitute default.
    ;
    ; sre_match_get_group_str hands back a fresh string the dict_set below
    ; adopts, and the DECREF_VAL after it releases this frame's reference.  The
    ; default is BORROWED from the caller's argument array, so it has to be
    ; INCREFed here or that DECREF_VAL takes the caller's reference instead:
    ; `d = m.groupdict('N/A')` left the dict holding a co_consts string it did
    ; not own, and the interpreter read freed memory at shutdown, when whichever
    ; of the two died first took the string with it.  groups() has always done
    ; this; groupdict() did not.
    IS_NONE rax, r8
    jne .gd_use_val
    mov rax, [rbp - GD_DEFAULT]
    mov edx, [rbp - GD_DEFAULT_TAG]
    INCREF_VAL rax, rdx
.gd_use_val:

    ; dict_set(result, name, val, val_tag, name_tag)
    push rax
    push rdx
    mov rdi, [rbp - GD_RESULT]
    mov rsi, r13               ; key
    ; rdx = val (still in rax from call), edx = val_tag
    mov rdx, [rsp + 8]        ; val payload
    mov ecx, [rsp]            ; val tag
    V_PACK rdx, rcx
    mov r8, r14                ; key tag
    V_PACK rsi, r8
    call dict_set
    ERR_M1 .gd_set_raised
    pop rdx
    pop rax
    DECREF_VAL rax, rdx

.gd_next:
    inc qword [rbp - GD_IDX]
    jmp .gd_loop

.gd_done:
    mov rax, [rbp - GD_RESULT]
    mov edx, TAG_PTR

    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
.gd_set_raised:
    pop rdx
    pop rax
    DECREF_VAL rax, rdx         ; the group's value
    mov rdi, [rbp - GD_RESULT]
    call obj_decref
    xor eax, eax
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC sre_match_groupdict_method

;; ============================================================================
;; sre_match_expand_method(self, args, nargs)
;; expand(template) -- the template mini-language, in src/pyo/sre_template.asm.
;; This used to hand the template straight back, so `\1` expanded to `\1`.
;; ============================================================================
EX_SELF   equ 8
EX_TMPL   equ 16
EX_FRAME  equ 32            ; + 0 pushes = 32

DEF_FUNC sre_match_expand_method, EX_FRAME
    ; rdi = args (fat array), rsi = nargs
    cmp rsi, 2
    jne .ex_args
    mov rax, [rdi]
    mov [rbp - EX_SELF], rax
    mov rax, [rdi + 8]
    mov [rbp - EX_TMPL], rax

    V_TEST_PTR rax, rcx
    ja .ex_type
    test rax, rax
    jz .ex_type                 ; V_TEST_PTR lets a NULL Value through
    ; A str SUBCLASS is a str.  An exact-type compare here refused
    ; m.expand(S(template)) for `class S(str)`, where CPython expands it and
    ; hands back a plain str -- and a template is exactly the sort of thing a
    ; program keeps in a str subclass of its own.
    ; And a bytes template for a bytes pattern: the two kinds must agree, as
    ; they do everywhere else in the engine.
    mov rcx, [rax + PyObject.ob_type]
    mov rdx, [rbp - EX_SELF]
    mov rdx, [rdx + SRE_MatchObject.pattern]
    cmp qword [rdx + SRE_PatternObject.is_bytes], 0
    jne .ex_want_bytes
    REQUIRE_STR_TYPE rcx, rdx, .ex_type
    jmp .ex_kind_ok
.ex_want_bytes:
    extern bytes_type
    lea rdx, [rel bytes_type]
    cmp rcx, rdx
    je .ex_kind_ok
    test qword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_BYTES_SUBCLASS
    jz .ex_type
.ex_kind_ok:

    mov rdi, rax
    mov rax, [rbp - EX_SELF]
    mov rsi, [rax + SRE_MatchObject.pattern]
    extern sre_template_parse
    call sre_template_parse
    ERR_NULL .ex_fail
    mov [rbp - EX_TMPL], rax

    mov rdi, rax
    mov rsi, [rbp - EX_SELF]
    extern sre_template_expand
    call sre_template_expand    ; err: its 0 is returned, once the template is released
    mov [rbp - EX_SELF], rax
    mov rdi, [rbp - EX_TMPL]
    call obj_decref
    mov rax, [rbp - EX_SELF]
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret

.ex_type:
    FAIL exc_TypeError_type, "expected str instance", .ex_fail
.ex_args:
    SET_EXC exc_TypeError_type, "expand() takes exactly one argument"
.ex_fail:
    xor eax, eax
    leave
    ret
END_FUNC sre_match_expand_method

;; ============================================================================
;; sre_match_copy_method(self, args, nargs)
;; __copy__ / __deepcopy__ — match objects are effectively immutable.
;; Returns self (INCREF'd).
;; ============================================================================
DEF_FUNC sre_match_copy_method
    ; rdi = args (fat array), rsi = nargs
    mov rax, [rdi]             ; self payload
    INCREF rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC sre_match_copy_method

;; ============================================================================
;; sre_match_subscript(self, key, key_tag) -> (rax, edx)
;; __getitem__ for match[group] indexing.
;; ============================================================================
DEF_FUNC sre_match_subscript
    V_UNPACK rsi, rdx           ; key Value -> (payload, tag)
    ; rdi = self, rsi = key payload, rdx = key tag
    push rbx
    push r12

    mov rbx, rdi               ; self
    mov r12, rsi               ; key payload

    ; Check tag: SmallInt = direct group index
    cmp edx, TAG_SMALLINT
    je .ms_int_key

    ; Check tag: string = named group lookup
    test edx, TAG_RC_BIT
    jz .ms_type_error

    ; String key: look up in pattern->groupindex
    mov rdi, [rbx + SRE_MatchObject.pattern]
    mov rdi, [rdi + SRE_PatternObject.groupindex]
    test rdi, rdi
    jz .ms_no_such_group

    ; dict_get(groupindex, key, key_tag)
    mov rsi, r12               ; key
    call dict_get       ; err: tested at .ms_group_miss
    V_UNPACK rax, rdx           ; dict_get returns a Value
    ; rax = val payload, edx = val tag
    test edx, edx               ; the tag, not the payload: a hit may be int 0
    jz .ms_group_miss

    ; group_idx = val payload (SmallInt)
    mov r12, rax               ; group index

.ms_int_key:
    mov rdi, rbx               ; self
    mov rsi, r12               ; group index
    call sre_match_get_group_str    ; err: its (0, 0) is this slot's own

    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.ms_no_such_group:
    FAIL exc_IndexError_type, "no such group", .ms_fail

.ms_type_error:
    SET_EXC exc_TypeError_type, "group index must be int or string"
.ms_fail:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
.ms_group_miss:
    cmp qword [gs:ThreadState.current_exception], 0
    je .ms_no_such_group
    jmp .ms_fail
END_FUNC sre_match_subscript

;; ============================================================================
;; sre_match_getattr(PyObject* self, PyObject* name) -> rax = Value
;; ============================================================================
DEF_FUNC sre_match_getattr
    push rbx
    push r12

    mov rbx, rdi               ; self
    mov r12, rsi               ; name

    lea rdi, [r12 + PyStrObject.data]

    ; Check methods
    lea rsi, [rel sm_group_str]
    call sre_strcmp
    test eax, eax
    jz .mga_group

    lea rdi, [r12 + PyStrObject.data]
    lea rsi, [rel sm_groups_str]
    call sre_strcmp
    test eax, eax
    jz .mga_groups

    lea rdi, [r12 + PyStrObject.data]
    lea rsi, [rel sm_groupdict_str]
    call sre_strcmp
    test eax, eax
    jz .mga_groupdict

    lea rdi, [r12 + PyStrObject.data]
    lea rsi, [rel sm_start_str]
    call sre_strcmp
    test eax, eax
    jz .mga_start

    lea rdi, [r12 + PyStrObject.data]
    lea rsi, [rel sm_end_str]
    call sre_strcmp
    test eax, eax
    jz .mga_end

    lea rdi, [r12 + PyStrObject.data]
    lea rsi, [rel sm_span_str]
    call sre_strcmp
    test eax, eax
    jz .mga_span

    ; Check attributes
    lea rdi, [r12 + PyStrObject.data]
    lea rsi, [rel sm_re_str]
    call sre_strcmp
    test eax, eax
    jz .mga_re

    lea rdi, [r12 + PyStrObject.data]
    lea rsi, [rel sm_string_str]
    call sre_strcmp
    test eax, eax
    jz .mga_string

    lea rdi, [r12 + PyStrObject.data]
    lea rsi, [rel sm_pos_str]
    call sre_strcmp
    test eax, eax
    jz .mga_pos

    lea rdi, [r12 + PyStrObject.data]
    lea rsi, [rel sm_endpos_str]
    call sre_strcmp
    test eax, eax
    jz .mga_endpos

    lea rdi, [r12 + PyStrObject.data]
    lea rsi, [rel sm_lastindex_str]
    call sre_strcmp
    test eax, eax
    jz .mga_lastindex

    lea rdi, [r12 + PyStrObject.data]
    lea rsi, [rel sm_lastgroup_str]
    call sre_strcmp
    test eax, eax
    jz .mga_lastgroup

    lea rdi, [r12 + PyStrObject.data]
    lea rsi, [rel sm_regs_str]
    call sre_strcmp
    test eax, eax
    jz .mga_regs

    lea rdi, [r12 + PyStrObject.data]
    lea rsi, [rel sm_expand_str]
    call sre_strcmp
    test eax, eax
    jz .mga_expand

    lea rdi, [r12 + PyStrObject.data]
    lea rsi, [rel sm_copy_str]
    call sre_strcmp
    test eax, eax
    jz .mga_copy

    lea rdi, [r12 + PyStrObject.data]
    lea rsi, [rel sm_deepcopy_str]
    call sre_strcmp
    test eax, eax
    jz .mga_copy

    ; Not found
    xor eax, eax
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

    ; --- Methods (create bound methods) ---
.mga_group:
    lea rdi, [rel sre_match_group_method]
    lea rsi, [rel sm_group_str]
    jmp .mga_bind
.mga_groups:
    lea rdi, [rel sre_match_groups_method]
    lea rsi, [rel sm_groups_str]
    jmp .mga_bind
.mga_groupdict:
    lea rdi, [rel sre_match_groupdict_method]
    lea rsi, [rel sm_groupdict_str]
    jmp .mga_bind
.mga_start:
    lea rdi, [rel sre_match_start_method]
    lea rsi, [rel sm_start_str]
    jmp .mga_bind
.mga_end:
    lea rdi, [rel sre_match_end_method]
    lea rsi, [rel sm_end_str]
    jmp .mga_bind
.mga_span:
    lea rdi, [rel sre_match_span_method]
    lea rsi, [rel sm_span_str]
    jmp .mga_bind

.mga_bind:
    push rbx                   ; save self for method_new
    call builtin_func_new      ; rax = builtin func wrapper
    pop rsi                    ; rsi = self (match object)
    mov rdi, rax               ; rdi = func
    push rax                   ; save for DECREF
    call method_new            ; rax = bound method
    push rax
    mov rdi, [rsp + 8]         ; DECREF builtin func (method_new INCREF'd)
    call obj_decref
    pop rax
    add rsp, 8
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

    ; --- Attributes ---
.mga_re:
    mov rax, [rbx + SRE_MatchObject.pattern]
    INCREF rax
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.mga_string:
    mov rax, [rbx + SRE_MatchObject.string]
    INCREF rax
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.mga_pos:
    mov rax, [rbx + SRE_MatchObject.pos]
    RET_TAG_SMALLINT
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.mga_endpos:
    mov rax, [rbx + SRE_MatchObject.endpos]
    RET_TAG_SMALLINT
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.mga_lastindex:
    mov rax, [rbx + SRE_MatchObject.lastindex]
    cmp rax, -1
    je .mga_lastindex_none
    RET_TAG_SMALLINT
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret
.mga_lastindex_none:
    xor eax, eax
    RET_NONE
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.mga_lastgroup:
    mov rax, [rbx + SRE_MatchObject.lastgroup]
    test rax, rax
    jz .mga_lastgroup_none
    INCREF rax
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret
.mga_lastgroup_none:
    xor eax, eax
    RET_NONE
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.mga_regs:
    ; Build tuple of (start, end) tuples for all groups
    push r13
    push r14
    push r15

    mov rax, [rbx + SRE_MatchObject.pattern]
    mov r14d, [rax + SRE_PatternObject.groups]
    inc r14d                   ; ngroups = groups + 1
    movsx r14, r14d

    ; Create outer tuple
    mov edi, r14d
    call tuple_new
    mov r15, rax               ; r15 = outer tuple

    xor r13d, r13d             ; i = 0
.mga_regs_loop:
    cmp r13, r14
    jge .mga_regs_done

    ; Get start/end marks for group i
    mov rcx, r13
    shl rcx, 1                 ; mark_index = i * 2
    lea rax, [rbx + SRE_MatchObject.marks]
    push qword [rax + rcx*8]      ; start
    push qword [rax + rcx*8 + 8]  ; end

    ; Create inner tuple (2 elements)
    mov edi, 2
    call tuple_new
    ; rax = inner tuple

    pop rcx                    ; end
    pop rdx                    ; start

    mov r8, [rax + PyTupleObject.ob_item]
    ; inner[0] = start, inner[1] = end
    V_PACK_I64 rdx, r9
    mov [r8], rdx
    V_PACK_I64 rcx, r9
    mov [r8 + 8], rcx

    ; Set outer[i] = inner (TAG_PTR)
    mov r10, [r15 + PyTupleObject.ob_item]       ; payloads
    mov [r10 + r13 * 8], rax

    inc r13
    jmp .mga_regs_loop

.mga_regs_done:
    mov rax, r15
    mov edx, TAG_PTR
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.mga_expand:
    lea rdi, [rel sre_match_expand_method]
    lea rsi, [rel sm_expand_str]
    jmp .mga_bind

.mga_copy:
    lea rdi, [rel sre_match_copy_method]
    lea rsi, [rel sm_copy_str]
    jmp .mga_bind
END_FUNC sre_match_getattr

; sre_strcmp is now shared from sre_pattern.asm (extern sre_strcmp)

;; ============================================================================
;; Type definition
;; ============================================================================
section .data
align 8

sre_match_mapping_methods:
    dq 0                       ; mp_length
    dq sre_match_subscript     ; mp_subscript
    dq 0                       ; mp_ass_subscript

align 8
sre_match_number_methods:
    dq 0                       ; nb_add
    dq 0                       ; nb_subtract
    dq 0                       ; nb_multiply
    dq 0                       ; nb_remainder
    dq 0                       ; nb_divmod
    dq 0                       ; nb_power
    dq 0                       ; nb_negative
    dq 0                       ; nb_positive
    dq 0                       ; nb_absolute
    dq sre_match_bool          ; nb_bool
    dq 0                       ; nb_invert
    dq 0                       ; nb_lshift
    dq 0                       ; nb_rshift
    dq 0                       ; nb_and
    dq 0                       ; nb_xor
    dq 0                       ; nb_or
    dq 0                       ; nb_int
    dq 0                       ; nb_float
    dq 0                       ; nb_floor_divide
    dq 0                       ; nb_true_divide
    dq 0                       ; nb_index
    dq 0                       ; nb_iadd
    dq 0                       ; nb_isub
    dq 0                       ; nb_imul
    dq 0                       ; nb_irem
    dq 0                       ; nb_ipow
    dq 0                       ; nb_ilshift
    dq 0                       ; nb_irshift
    dq 0                       ; nb_iand
    dq 0                       ; nb_ixor
    dq 0                       ; nb_ior
    dq 0                       ; nb_ifloor_divide
    dq 0                       ; nb_itrue_divide
    dq 0 ; nb_matmul
    dq 0 ; nb_imatmul

align 8
global sre_match_type
sre_match_type:
    dq 0x00000000FFFFFFFF       ; ob_ref_local=IMMORTAL, ob_ref_shared=0
    dq 0                        ; ob_tid=0 (immortal), ob_mutex=0
    dq type_type               ; ob_type
    dq sm_type_name            ; tp_name
    dq SRE_MatchObject_size    ; tp_basicsize
    dq sre_match_dealloc       ; tp_dealloc
    dq sre_match_repr          ; tp_repr
    dq sre_match_repr          ; tp_str
    dq 0                       ; tp_hash
    dq 0                       ; tp_call
    dq sre_match_getattr       ; tp_getattr
    dq 0                       ; tp_setattr
    dq 0                       ; tp_richcompare
    dq 0                       ; tp_iter
    dq 0                       ; tp_iternext
    dq 0                       ; tp_init
    dq 0                       ; tp_new
    dq sre_match_number_methods ; tp_as_number
    dq 0                       ; tp_as_sequence
    dq sre_match_mapping_methods ; tp_as_mapping
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
sm_type_name:      db "re.Match", 0
sm_group_str:      db "group", 0
sm_groups_str:     db "groups", 0
sm_groupdict_str:  db "groupdict", 0
sm_start_str:      db "start", 0
sm_end_str:        db "end", 0
sm_span_str:       db "span", 0
sm_re_str:         db "re", 0
sm_string_str:     db "string", 0
sm_pos_str:        db "pos", 0
sm_endpos_str:     db "endpos", 0
sm_lastindex_str:  db "lastindex", 0
sm_lastgroup_str:  db "lastgroup", 0
sm_regs_str:       db "regs", 0
sm_expand_str:     db "expand", 0
sm_copy_str:       db "__copy__", 0
sm_deepcopy_str:   db "__deepcopy__", 0
