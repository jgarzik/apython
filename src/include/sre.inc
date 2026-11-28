; sre.inc - SRE (regex) structs and constants for apython
; Implements CPython's _sre module data structures

%ifndef SRE_INC
%define SRE_INC

; ============================================================================
; SRE Opcodes (CPython u32 format)
; ============================================================================
SRE_OP_FAILURE           equ 0
SRE_OP_SUCCESS           equ 1
SRE_OP_ANY               equ 2
SRE_OP_ANY_ALL           equ 3
SRE_OP_ASSERT            equ 4
SRE_OP_ASSERT_NOT        equ 5
SRE_OP_AT                equ 6
SRE_OP_BRANCH            equ 7
SRE_OP_CATEGORY          equ 8
SRE_OP_CHARSET           equ 9
SRE_OP_BIGCHARSET        equ 10
SRE_OP_GROUPREF          equ 11
SRE_OP_GROUPREF_EXISTS   equ 12
SRE_OP_IN                equ 13
SRE_OP_INFO              equ 14
SRE_OP_JUMP              equ 15
SRE_OP_LITERAL           equ 16
SRE_OP_MARK              equ 17
SRE_OP_MAX_UNTIL         equ 18
SRE_OP_MIN_UNTIL         equ 19
SRE_OP_NOT_LITERAL       equ 20
SRE_OP_NEGATE            equ 21
SRE_OP_RANGE             equ 22
SRE_OP_REPEAT            equ 23
SRE_OP_REPEAT_ONE        equ 24
SRE_OP_SUBPATTERN        equ 25
SRE_OP_MIN_REPEAT_ONE    equ 26
SRE_OP_ATOMIC_GROUP      equ 27
SRE_OP_POSSESSIVE_REPEAT equ 28
SRE_OP_POSSESSIVE_REPEAT_ONE equ 29
SRE_OP_GROUPREF_IGNORE       equ 30
SRE_OP_IN_IGNORE             equ 31
SRE_OP_LITERAL_IGNORE        equ 32
SRE_OP_NOT_LITERAL_IGNORE    equ 33
SRE_OP_GROUPREF_LOC_IGNORE   equ 34
SRE_OP_IN_LOC_IGNORE         equ 35
SRE_OP_LITERAL_LOC_IGNORE    equ 36
SRE_OP_NOT_LITERAL_LOC_IGNORE equ 37
SRE_OP_GROUPREF_UNI_IGNORE   equ 38
SRE_OP_IN_UNI_IGNORE         equ 39
SRE_OP_LITERAL_UNI_IGNORE    equ 40
SRE_OP_NOT_LITERAL_UNI_IGNORE equ 41
SRE_OP_RANGE_UNI_IGNORE      equ 42
SRE_OP_COUNT                 equ 43

; ============================================================================
; SRE AT codes (for SRE_OP_AT) — must match CPython's re._constants.ATCODES
; ============================================================================
SRE_AT_BEGINNING         equ 0
SRE_AT_BEGINNING_LINE    equ 1
SRE_AT_BEGINNING_STRING  equ 2
SRE_AT_BOUNDARY          equ 3
SRE_AT_NON_BOUNDARY      equ 4
SRE_AT_END               equ 5
SRE_AT_END_LINE          equ 6
SRE_AT_END_STRING        equ 7
SRE_AT_LOC_BOUNDARY      equ 8
SRE_AT_LOC_NON_BOUNDARY  equ 9
SRE_AT_UNI_BOUNDARY      equ 10
SRE_AT_UNI_NON_BOUNDARY  equ 11

; ============================================================================
; SRE Category codes (for SRE_OP_CATEGORY)
; ============================================================================
SRE_CATEGORY_DIGIT       equ 0
SRE_CATEGORY_NOT_DIGIT   equ 1
SRE_CATEGORY_SPACE       equ 2
SRE_CATEGORY_NOT_SPACE   equ 3
SRE_CATEGORY_WORD        equ 4
SRE_CATEGORY_NOT_WORD    equ 5
SRE_CATEGORY_LINEBREAK   equ 6
SRE_CATEGORY_NOT_LINEBREAK equ 7
SRE_CATEGORY_LOC_WORD    equ 8
SRE_CATEGORY_LOC_NOT_WORD equ 9
SRE_CATEGORY_UNI_DIGIT   equ 10
SRE_CATEGORY_UNI_NOT_DIGIT equ 11
SRE_CATEGORY_UNI_SPACE   equ 12
SRE_CATEGORY_UNI_NOT_SPACE equ 13
SRE_CATEGORY_UNI_WORD    equ 14
SRE_CATEGORY_UNI_NOT_WORD equ 15
SRE_CATEGORY_UNI_LINEBREAK equ 16
SRE_CATEGORY_UNI_NOT_LINEBREAK equ 17

; ============================================================================
; SRE Flags (match CPython's re module flags)
; ============================================================================
SRE_FLAG_IGNORECASE  equ 0x02
SRE_FLAG_MULTILINE   equ 0x08
SRE_FLAG_DOTALL      equ 0x10
SRE_FLAG_UNICODE     equ 0x20
SRE_FLAG_ASCII       equ 0x100
SRE_FLAG_TEMPLATE    equ 0x01
SRE_FLAG_LOCALE      equ 0x04
SRE_FLAG_VERBOSE     equ 0x40
SRE_FLAG_DEBUG       equ 0x80

; ============================================================================
; SRE INFO flags (embedded in SRE_OP_INFO)
; ============================================================================
SRE_INFO_PREFIX      equ 1
SRE_INFO_LITERAL     equ 2
SRE_INFO_CHARSET     equ 4

; ============================================================================
; SRE Constants
; ============================================================================
SRE_MAGIC            equ 20221023
SRE_CODESIZE         equ 4
SRE_MAXREPEAT        equ 0xFFFFFFFF
SRE_MAXGROUPS        equ 0x3FFFFFFF

; Match results
SRE_MATCH_FAILURE    equ 0
SRE_MATCH_SUCCESS    equ 1
SRE_MATCH_ERROR      equ -1

; ============================================================================
; SRE_PatternObject layout (64 bytes)
; ============================================================================
struc SRE_PatternObject
    .ob_ref_local:  resd 1  ; +0:  owner-local refcount (0xFFFFFFFF=immortal)
    .ob_ref_shared: resd 1  ; +4:  (shared_rc << 2) | flags (MERGED=1, QUEUED=2)
    .ob_tid:        resd 1  ; +8:  owner ts_tid (0=immortal, 0xFFFFFFFF=merged)
    .ob_mutex:      resd 1  ; +12: 32-bit direct futex lock
    .ob_type:       resq 1  ; +16: pointer to type object
    .pattern:     resq 1  ; +16: pattern string (PyStrObject*)
    .flags:       resd 1  ; +24: regex flags
    .groups:      resd 1  ; +28: number of groups
    .groupindex:  resq 1  ; +32: group name -> index dict (PyDictObject* or NULL)
    .indexgroup:  resq 1  ; +40: index -> group name tuple (PyTupleObject* or NULL)
    .code:        resq 1  ; +48: u32* compiled pattern code
    .code_len:    resq 1  ; +56: number of u32 code words
    ; Whether the pattern was compiled from BYTES.  A bytes pattern matches
    ; bytes-like subjects and answers bytes; a str pattern matches str and
    ; answers str, and mixing them is a TypeError.  The engine itself is the
    ; same: bytes are byte-indexed, which is the ASCII path it already has.
    .is_bytes:    resq 1  ; +64
endstruc

; ============================================================================
; SRE_MatchObject layout (80 bytes + variable marks)
; ============================================================================
struc SRE_MatchObject
    .ob_ref_local:  resd 1  ; +0:  owner-local refcount (0xFFFFFFFF=immortal)
    .ob_ref_shared: resd 1  ; +4:  (shared_rc << 2) | flags (MERGED=1, QUEUED=2)
    .ob_tid:        resd 1  ; +8:  owner ts_tid (0=immortal, 0xFFFFFFFF=merged)
    .ob_mutex:      resd 1  ; +12: 32-bit direct futex lock
    .ob_type:       resq 1  ; +16: pointer to type object
    .pattern:     resq 1  ; +16: SRE_PatternObject* (INCREF'd)
    .string:      resq 1  ; +24: original string (PyStrObject*, INCREF'd)
    .str_begin:   resq 1  ; +32: ptr to start of string data
    .pos:         resq 1  ; +40: search start position (char index)
    .endpos:      resq 1  ; +48: search end position (char index)
    .lastindex:   resq 1  ; +56: last matched group index (-1 if none)
    .lastgroup:   resq 1  ; +64: last matched group name (str* or NULL)
    .marks_count: resq 1  ; +72: number of mark pairs (* 2)
    .marks:                ; +80: pairs of i64 char offsets (variable, marks_count * 8)
endstruc

; ============================================================================
; SRE_State (stack-allocated match state, 128 bytes)
; Used internally during matching, NOT a Python object.
; ============================================================================
struc SRE_State
    .str_begin:     resq 1  ; +0: ptr to start of string data
    .str_end:       resq 1  ; +8: ptr past end of string data
    .str_pos:       resq 1  ; +16: current match position (char index)
    .str_start:     resq 1  ; +24: match start position (char index)
    .pattern:       resq 1  ; +32: SRE_PatternObject*
    .string_obj:    resq 1  ; +40: original string PyObject*
    .marks:         resq 1  ; +48: i64* array of mark positions
    .marks_count:   resq 1  ; +56: number of marks allocated (capacity)
    .marks_size:    resq 1  ; +64: number of marks used (actual count)
    .lastmark:      resq 1  ; +72: highest mark set
    .lastindex:     resq 1  ; +80: last group index matched
    .repeat_ctx:    resq 1  ; +88: SRE_RepeatContext* chain
    .flags:         resd 1  ; +96: regex flags
    .match_all:     resd 1  ; +100: 1 if fullmatch mode
    .is_bytes:      resd 1  ; +104: 1 if matching bytes, 0 if str
    .charsize:      resd 1  ; +108: 1=ASCII byte, 4=u32 codepoint
    .codepoint_buf: resq 1  ; +112: u32* decoded codepoints (NULL for ASCII)
    .codepoint_len: resq 1  ; +120: number of codepoints
    .original_pos:  resq 1  ; +128: original pos arg (for match.pos)
    .match_depth:   resd 1  ; +136: current recursion depth
    ; Set by the scanning methods after an empty match, and consulted at
    ; SUCCESS: CPython 3.7 replaced "step one character past an empty match"
    ; with "search the same position again, forbidding another empty match
    ; there", which is what lets '.*?' find 'a' where it had just found ''.
    .must_advance:  resd 1  ; +140: forbid an empty match at search_origin
    .search_origin: resq 1  ; +144: where the current search began
    ; 0 when codepoint_buf is borrowed from an SRE_CpCache that outlives this
    ; state.  sre_state_init's construction zeroes the whole struct, so a path
    ; that allocates has to say so; sre_state_fini frees only what it owns.
    ; A qword rather than a dword because the zero loop clears
    ; SRE_State_size/8 qwords, and an odd tail would go unzeroed.
    .owns_cpbuf:    resd 1  ; +152: 1 = this state must free codepoint_buf
    ; Set when the matcher raised (the recursion limit).  Every sre_match
    ; entered or left after that answers "no match", so the error climbs out
    ; through the ordinary failure paths -- which are the ones that free the
    ; saved marks and the repeat contexts -- and sre_search and the two
    ; direct callers read it to tell a raise from a miss.
    .error:         resd 1  ; +156: 1 = an exception is pending from the match
    .cpcache:       resq 1  ; +160: the SRE_CpCache this state BORROWED from,
                            ;       or 0.  sre_state_fini releases the borrow
                            ;       so the cache knows when it may evict.
endstruc

; ============================================================================
; SRE_CpCache -- a decoded subject held across matches.
;
; Decoding a non-ASCII subject to u32 is O(len), and a scanner builds a fresh
; SRE_State per iteration, so finditer over such a string used to re-decode it
; on every step.  The scanner owns one of these and hands it to
; sre_state_init, which fills it on the first miss and borrows it thereafter.
; It holds the UNCLAMPED decode: endpos narrows codepoint_len per call and
; must keep measuring against the whole string.
; ============================================================================
struc SRE_CpCache
    .buf:  resq 1  ; +0: u32* decoded codepoints, NULL until first filled
    .len:  resq 1  ; +8: codepoints in .buf, before any endpos clamp
    ; Which subject .buf is the decode of, an OWNED reference.  A scanner's
    ; cache never needs it -- one scanner has one subject for its whole life
    ; -- but the module-level cache the pattern methods share is handed a
    ; different string every other call, and a borrowed pointer there would
    ; let a freed str's reused address pass for a hit.
    .subject: resq 1  ; +16: PyStrObject*, owned, or 0
    ; How many live SRE_States are reading .buf.  Evicting is a free, and a
    ; scan that is still running holds a BORROWED pointer into it: sub, subn,
    ; split and findall all run user code between matches, so a nested regex
    ; on a different subject could pull the buffer out from under the outer
    ; one.  Eviction waits for this to reach zero and decodes privately
    ; meanwhile.
    .borrows: resq 1  ; +24
endstruc

; Recursion depth limit (matches CPython's default)
SRE_MAX_RECURSION equ 10000

; ============================================================================
; SRE_RepeatContext (for REPEAT/MAX_UNTIL/MIN_UNTIL backtracking)
; Linked list, stack-allocated during recursive sre_match calls.
; ============================================================================
struc SRE_RepeatContext
    .count:     resq 1  ; +0: current repeat count
    .pattern:   resq 1  ; +8: u32* to REPEAT opcode in pattern
    .prev:      resq 1  ; +16: previous repeat context (linked list)
    .last_pos:  resq 1  ; +24: last match position (for zero-width detect)
endstruc

; ============================================================================
; SRE_ScannerObject layout
; Used by Pattern.finditer() and Pattern.scanner().
; ============================================================================
struc SRE_ScannerObject
    .ob_ref_local:  resd 1  ; +0:  owner-local refcount (0xFFFFFFFF=immortal)
    .ob_ref_shared: resd 1  ; +4:  (shared_rc << 2) | flags (MERGED=1, QUEUED=2)
    .ob_tid:        resd 1  ; +8:  owner ts_tid (0=immortal, 0xFFFFFFFF=merged)
    .ob_mutex:      resd 1  ; +12: 32-bit direct futex lock
    .ob_type:       resq 1  ; +16: pointer to type object
    .pattern:     resq 1  ; +16  SRE_PatternObject* (INCREF'd)
    .string:      resq 1  ; +24  PyStrObject* (INCREF'd)
    .pos:         resq 1  ; +32  current search position (i64)
    .endpos:      resq 1  ; +40  end position (i64)
    ; The scanner builds a fresh SRE_State per call, so the "the last match
    ; was empty" flag has to live here rather than in the state.
    .must_advance: resq 1 ; +48  forbid an empty match at pos
    ; An SRE_CpCache, for the same reason: every iteration would otherwise
    ; re-decode the subject.  Safe here and not in general because the scanner
    ; holds a reference to .string for its whole life and str is immutable, so
    ; the buffer can neither outlive its subject nor go stale.
    .cp_buf:       resq 1 ; +56  SRE_CpCache.buf
    .cp_len:       resq 1 ; +64  SRE_CpCache.len
    .cp_subject:   resq 1 ; +72  SRE_CpCache.subject
    .cp_borrows:   resq 1 ; +80  SRE_CpCache.borrows -- these four ARE an
                          ;      SRE_CpCache, laid out inline, and
                          ;      sre_state_init is handed a pointer to the
                          ;      first.  Growing that struct means growing
                          ;      this, and the four must stay adjacent.
endstruc

; Initial marks array size (number of i64 slots)
SRE_MARKS_INITIAL equ 64

%endif ; SRE_INC

;; SRE_SUBJECT_LEN reg -- rax = the subject's length in the unit the engine
;; indexes: bytes for an ASCII subject, code points for a decoded one.  This
;; was written out seven times; it is a macro rather than a function because
;; every site holds live values in r8/r9 that a call would put at risk.
%macro SRE_SUBJECT_LEN 1        ; %1 = the register holding SRE_State*
    mov rax, [%1 + SRE_State.codepoint_buf]
    test rax, rax
    jnz %%uni
    mov rax, [%1 + SRE_State.str_end]
    sub rax, [%1 + SRE_State.str_begin]
    jmp %%done
%%uni:
    mov rax, [%1 + SRE_State.codepoint_len]
%%done:
%endmacro
