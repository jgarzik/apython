; pyexpat_cb.asm - the callback side of the pyexpat shim.
;
; Everything here is called BY LIBEXPAT.  That is the whole reason it is a
; separate file from src/modules/pyexpat.asm, which is called by Python: the
; two sides have different ABIs, different alignment rules and -- the one that
; matters -- opposite error discipline.
;
;   **NEVER `RAISE` FROM THIS FILE.**
;
; `RAISE` and `raise_exception` tail-jump into `eval_exception_unwind`, which
; does `mov rsp, [gs:ThreadState.eval_base_rsp]` and never comes back -- from a
; trampoline that would discard every libexpat frame between here and
; XML_Parse, without libexpat ever getting the chance to clean up.  Use
; `set_exception`, then `px_stop`, then RETURN.  eval.asm's own docblock for
; set_exception says the same thing for the same reason.
;
; The mechanism a trampoline rests on is that a called PYTHON function which
; raises returns control here normally.  `eval_frame` publishes
; `eval_base_rsp` as its OWN rsp, and `eval_exception_unwind` with no handler
; in the frame reaches `eval_return`, which restores the caller's eval globals
; and returns 0 with `current_exception` set.  So the five callee-saved
; registers libexpat entrusted to us are intact and its frames are untouched.
; Measured over list.sort(key=), map, filter, min, dict hashing, dict __eq__,
; with.__exit__ and str.translate before any of this was written.
;
; The interpreter's rbx/r12-r15 convention needs NOTHING done to it, and the
; reason is worth writing down because the opposite is the natural assumption.
; Those registers are not trustworthy at entry -- libexpat saved them on the
; way into its own function and uses them as it likes -- but nothing here
; needs them: `eval_frame` links `PyFrame.prev_frame` from the GLOBAL
; `eval_saved_r12`, not from r12, and `func_call` takes builtins from
; `builtins_dict_global` for the same reason.  So a trampoline saves only what
; it uses itself.
;
; Two behaviours in this file are ours rather than libexpat's, and both live
; here rather than in Python because they are about the STREAM of C callbacks:
; the character-data coalescing that `buffer_text` turns on, and the interning
; that makes a repeated tag name the same object.

%include "macros.inc"
%include "object.inc"
%include "pyexpat.inc"

ASM_INIT

extern obj_call_n
extern obj_decref
extern obj_dealloc
extern obj_incref
extern str_from_cstr_heap
extern str_new_heap
extern dict_new
extern dict_set
extern dict_get
extern none_singleton
extern set_exception
extern exc_TypeError_type

extern XML_StopParser
extern XML_SetCharacterDataHandler
extern px_installers
extern XML_GetSpecifiedAttributeCount
extern XML_SetProcessingInstructionHandler
extern XML_SetCommentHandler
extern XML_SetStartCdataSectionHandler
extern XML_SetEndCdataSectionHandler
extern XML_SetUnparsedEntityDeclHandler
extern XML_SetNotationDeclHandler
extern XML_SetStartNamespaceDeclHandler
extern XML_SetEndNamespaceDeclHandler
extern XML_SetStartDoctypeDeclHandler
extern XML_SetEndDoctypeDeclHandler
extern XML_SetXmlDeclHandler
extern XML_SetAttlistDeclHandler
extern XML_SetSkippedEntityHandler
extern int_from_i64
extern list_new_filled

section .text

; The common frame every macro-built trampoline uses.  One layout rather than
; one per handler, because the bodies differ only in how many strings arrive
; and which of them are interned.
CB_H     equ 8                  ; the PxHandle*
CB_RAW   equ 56                 ; up to 6 const char*, at [rbp-56 .. rbp-16]
CB_INT   equ 64                 ; the trailing int, for the handlers that have one
CB_ARGS  equ 120                ; up to 7 Values, at [rbp-120 .. rbp-72]
CB_FRAME equ 128                ; + 0 pushes = 128, 16-aligned

;; Save the C string arguments, which arrive in rsi, rdx, rcx, r8, r9.  They
;; have to be saved BEFORE anything else runs: px_flush calls Python.
%macro PX_SAVE_RAW 1            ; %1 = how many
    mov [rbp - CB_RAW], rsi
%if %1 > 1
    mov [rbp - CB_RAW + 8], rdx
%endif
%if %1 > 2
    mov [rbp - CB_RAW + 16], rcx
%endif
%if %1 > 3
    mov [rbp - CB_RAW + 24], r8
%endif
%if %1 > 4
    mov [rbp - CB_RAW + 32], r9
%endif
%endmacro

;; A trampoline whose arguments are N C strings and nothing else.
;;
;;   PX_CB_STR name, handler_index, count, intern_mask
;;
;; Bit i of the mask means "intern argument i".  The split is CPython's and it
;; is not arbitrary: a NAME repeats across a document and a VALUE usually does
;; not, so interning the first saves memory and interning the second wastes it.
%macro PX_CB_STR 4
DEF_FUNC %1, CB_FRAME
    mov [rbp - CB_H], rdi
    PX_SAVE_RAW %3
    cmp qword [rdi + PxHandle.magic], PX_MAGIC
    jne %%out
    cmp qword [gs:ThreadState.current_exception], 0
    jne %%out
    call px_flush               ; every handler but character data flushes
    test eax, eax
    js %%out
    mov rdi, [rbp - CB_H]
    lea rsi, [rbp - CB_RAW]
    mov edx, %3
    mov ecx, %4
    lea r8, [rbp - CB_ARGS]
    call px_marshal
    test eax, eax
    js %%out
    mov rdi, [rbp - CB_H]
    mov esi, %2
    lea rdx, [rbp - CB_ARGS]
    mov ecx, %3
    call px_call
    test rax, rax
    jz %%release
    mov rdi, rax
    DECREF_V rdi, rcx
%%release:
    lea rdi, [rbp - CB_ARGS]
    mov esi, %3
    call px_release
%%out:
    leave
    ret
END_FUNC %1
%endmacro

;; The same, plus a trailing int: has_internal_subset, standalone,
;; isrequired, is_parameter_entity.
%macro PX_CB_STR_INT 4          ; %1 name, %2 index, %3 string count, %4 mask
DEF_FUNC %1, CB_FRAME
    mov [rbp - CB_H], rdi
    PX_SAVE_RAW %3
%if %3 == 1
    mov [rbp - CB_INT], rdx
%elif %3 == 2
    mov [rbp - CB_INT], rcx
%elif %3 == 3
    mov [rbp - CB_INT], r8
%elif %3 == 4
    mov [rbp - CB_INT], r9
%endif
    cmp qword [rdi + PxHandle.magic], PX_MAGIC
    jne %%out
    cmp qword [gs:ThreadState.current_exception], 0
    jne %%out
    call px_flush
    test eax, eax
    js %%out
    mov rdi, [rbp - CB_H]
    lea rsi, [rbp - CB_RAW]
    mov edx, %3
    mov ecx, %4
    lea r8, [rbp - CB_ARGS]
    call px_marshal
    test eax, eax
    js %%out
    movsx rdi, dword [rbp - CB_INT]
    call int_from_i64
    V_PACK rax, rdx
    mov [rbp - CB_ARGS + %3 * 8], rax
    mov rdi, [rbp - CB_H]
    mov esi, %2
    lea rdx, [rbp - CB_ARGS]
    mov ecx, %3 + 1
    call px_call
    test rax, rax
    jz %%release
    mov rdi, rax
    DECREF_V rdi, rcx
%%release:
    lea rdi, [rbp - CB_ARGS]
    mov esi, %3 + 1
    call px_release
%%out:
    leave
    ret
END_FUNC %1
%endmacro

;; A trampoline with no arguments at all: the two CDATA boundaries and the end
;; of a doctype.
%macro PX_CB_VOID 2             ; %1 name, %2 index
DEF_FUNC %1, CB_FRAME
    mov [rbp - CB_H], rdi
    cmp qword [rdi + PxHandle.magic], PX_MAGIC
    jne %%out
    cmp qword [gs:ThreadState.current_exception], 0
    jne %%out
    call px_flush
    test eax, eax
    js %%out
    mov rdi, [rbp - CB_H]
    mov esi, %2
    xor edx, edx
    xor ecx, ecx
    call px_call
    test rax, rax
    jz %%out
    mov rdi, rax
    DECREF_V rdi, rcx
%%out:
    leave
    ret
END_FUNC %1
%endmacro

;; ============================================================================
;; px_call(rdi = PxHandle*, esi = handler index, rdx = Value *args,
;;         ecx = nargs) -> rax = the result Value (owned), or 0 with an
;;         exception pending and the parser stopped
;;
;; The one path from libexpat to a Python handler.  It does four things before
;; the call and one after, and each of the five is load-bearing:
;;
;; 1. Refuses to run at all if an exception is already pending -- which is
;;    `pyexpat.c`'s `if (PyErr_Occurred()) return;` at the head of every
;;    handler.  It is what makes an abort take effect on the first event after
;;    a raise rather than only when XML_Parse returns.
;; 2. Re-reads the handler out of the handle, because a handler may have been
;;    CLEARED by an earlier callback in the same parse.
;; 3. Clears `kw_names_pending`.  Not defensive noise: eval.asm records the
;;    bug -- a builtin that ignores KW_NAMES leaves it set, and the first
;;    Python frame entered underneath reads the stale names as its own
;;    keywords.  `parser_parse` is exactly such a builtin, and the first frame
;;    under it is a handler's.
;; 4. Marks in_callback, which is what XML_GetInputContext is only valid
;;    during.
;; 5. On a 0 return, stops the parser and records it -- see px_stop.
;;
;; obj_call_n's OCN_MAX is 8 and the widest handler here is EntityDeclHandler
;; at 7 Python arguments, so every one fits with no second path.  A ninth
;; would silently become "not callable"; there is no ninth.
;; ============================================================================
PC_H      equ 8
PC_ARGS   equ 16
PC_NARGS  equ 24
PC_FN     equ 32
PC_FRAME  equ 48                ; + 1 push = 56 ... padded below
DEF_FUNC px_call, 56
    push rbx
    mov [rbp - PC_H], rdi
    mov [rbp - PC_ARGS], rdx
    mov [rbp - PC_NARGS], rcx
    movsx rsi, esi

    cmp qword [gs:ThreadState.current_exception], 0
    jne .stopped

    mov rax, [rdi + PxHandle.handlers + rsi*8]
    test rax, rax
    jz .stopped
    mov [rbp - PC_FN], rax

    mov qword [gs:ThreadState.kw_names_pending], 0
    mov rcx, [rbp - PC_H]
    mov qword [rcx + PxHandle.in_callback], 1

    mov rdi, rax
    mov rsi, [rbp - PC_ARGS]
    mov rdx, [rbp - PC_NARGS]
    call obj_call_n

    mov rcx, [rbp - PC_H]
    mov qword [rcx + PxHandle.in_callback], 0
    test rax, rax
    jz .raised
    pop rbx
    leave
    ret

.raised:
    mov rdi, [rbp - PC_H]
    call px_stop
    xor eax, eax
    pop rbx
    leave
    ret
.stopped:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC px_call

;; ============================================================================
;; px_stop(rdi = PxHandle*) -> nothing; stops the parse and takes every
;;     handler out of libexpat's hands
;;
;; `pyexpat.c`'s flag_error plus its noop_character_data_handler.  Two parts:
;;
;; XML_StopParser(p, XML_FALSE) -- non-resumable, so XML_Parse returns
;; XML_STATUS_ERROR and any later Parse answers XML_ERROR_FINISHED rather than
;; carrying on with a half-built tree.
;;
;; Then EVERY handler libexpat currently holds is taken back, by walking
;; px_installers rather than by naming them: the table is the list of handlers
;; that have a C side, so this stays complete as rows are filled in.  Naming
;; three of them by hand was how the docblock came to claim something the code
;; did not do.
;;
;; The character-data handler is REPLACED with a no-op rather than removed,
;; which is CPython's own arrangement and its comment gives the reason: it
;; cannot be safely removed from inside itself.
;;
;; `.raised` is set so parser_parse can tell "a handler raised" from "libexpat
;; found a syntax error" without inspecting an exception type -- see the
;; three-valued return there.
;; ============================================================================
PST_H     equ 8
PST_I     equ 16
PST_FRAME equ 32                ; + 0 pushes = 32, 16-aligned
DEF_FUNC px_stop, PST_FRAME
    mov [rbp - PST_H], rdi
    mov qword [rdi + PxHandle.raised], 1
    mov rdi, [rdi + PxHandle.parser]
    test rdi, rdi
    jz .out
    xor esi, esi                ; XML_FALSE: not resumable
    call XML_StopParser wrt ..plt

    mov qword [rbp - PST_I], 0
.strip:
    mov rax, [rbp - PST_I]
    cmp rax, PX_H_COUNT
    jae .out
    shl rax, 4                  ; two qwords a row; x86 has no *16 scale
    lea rcx, [rel px_installers]
    add rcx, rax
    mov rdx, [rcx]              ; the libexpat setter, or 0 for no C side
    test rdx, rdx
    jz .strip_next
    mov rcx, [rbp - PST_H]
    mov rdi, [rcx + PxHandle.parser]
    xor esi, esi
    cmp qword [rbp - PST_I], PX_H_CHARACTER_DATA
    jne .strip_call
    lea rsi, [rel px_cb_noop_chardata]
.strip_call:
    call rdx
.strip_next:
    inc qword [rbp - PST_I]
    jmp .strip
.out:
    leave
    ret
END_FUNC px_stop

;; ============================================================================
;; px_cb_noop_chardata(userData, s, len) -> nothing
;;
;; What the character-data slot holds after px_stop.  See px_stop.
;; ============================================================================
DEF_FUNC_BARE px_cb_noop_chardata
    ret
END_FUNC px_cb_noop_chardata

;; ============================================================================
;; px_intern(rdi = PxHandle*, rsi = a NUL-terminated name) -> rax = an owned
;;     str, or 0 on failure
;;
;; A repeated tag name has to be the SAME object: `expatbuilder` relies on it,
;; and reaches into `parser.intern` with `setdefault` itself, which is why the
;; table is an ordinary dict rather than something private.
;;
;; CPython's string_intern, including the corner that a NULL `char*` becomes
;; None and is then interned AS A KEY, leaving a `None: None` entry in
;; parser.intern.  Matching it is free and parser.intern is observable.
;; ============================================================================
PI_H      equ 8
PI_STR    equ 16
PI_FRAME  equ 32                ; + 1 push = 40 ... padded below
DEF_FUNC px_intern, 40
    push rbx
    mov [rbp - PI_H], rdi
    test rsi, rsi
    jz .null_name
    mov rdi, rsi
    call str_from_cstr_heap
    test rax, rax
    jz .fail
    mov [rbp - PI_STR], rax

    mov rcx, [rbp - PI_H]
    mov rbx, [rcx + PxHandle.intern]
    test rbx, rbx
    jz .no_table            ; no intern dict: the fresh string is the answer

    mov rdi, rbx
    mov rsi, rax
    call dict_get           ; a Value; 0 is the miss
    test rax, rax
    jz .insert
    ; A hit: hand back the stored one and drop the copy just built.
    ;
    ; dict_get answers a VALUE, and `parser.intern` is the CALLER's dict --
    ; documented, public, and written into by expatbuilder with setdefault --
    ; so it can hold an int, a float or None as easily as a str.  CPython hands
    ; back whatever is there without a type check, and so does this; but the
    ; refcounting has to be Value-aware, or an immediate int is dereferenced
    ; as a pointer to 0xFFF8...  `ParserCreate(intern={"a": 5})` then parsing
    ; `<a/>` segfaulted.  Every release of an interned result below is
    ; DECREF_V for the same reason.
    mov rbx, rax
    INCREF_V rbx, rcx
    mov rdi, [rbp - PI_STR]
    call obj_decref             ; always a fresh str, so always a pointer
    mov rax, rbx
    pop rbx
    leave
    ret
.insert:
    mov rdi, rbx
    mov rsi, [rbp - PI_STR]
    mov rdx, rsi            ; interned as its own key AND value
    call dict_set
.no_table:
    mov rax, [rbp - PI_STR]
    pop rbx
    leave
    ret
.null_name:
    lea rax, [rel none_singleton]
    INCREF rax
    pop rbx
    leave
    ret
.fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC px_intern

;; ============================================================================
;; px_flush(rdi = PxHandle*) -> eax = 0 normally, -1 if a handler raised
;;
;; flush_character_buffer.  Nothing to do until buffer_text turns the buffer
;; on, which is a later commit; the call sites are all here already, because
;; the ORDER matters -- every other trampoline has to flush before it fires,
;; or coalesced text arrives after the element that follows it.
;; ============================================================================
DEF_FUNC_BARE px_flush
    xor eax, eax
    ret
END_FUNC px_flush

;; ============================================================================
;; px_cb_start_element(rdi = userData, rsi = name, rdx = atts) -> nothing
;;
;; atts is a NULL-terminated array of alternating name/value pointers.  The
;; NAMES are interned and the VALUES are not, which is CPython's split and not
;; an arbitrary one: a document has few distinct attribute names and many
;; distinct values.
;; ============================================================================
SE_H      equ 8
SE_ATTS   equ 16
SE_RAWNAME equ 24           ; the const char* libexpat handed over
SE_NAME   equ 32            ; the interned str
SE_DICT   equ 40
SE_KEY    equ 48
SE_N      equ 56            ; how many attributes to publish
SE_AT     equ 64            ; which one is being built
SE_ISLIST equ 72            ; ordered_attributes wants a flat list
SE_ITEMS  equ 80            ; the list's payload array, when it is a list
SE_ARGS   equ 96            ; two Values
SE_FRAME  equ 112           ; + 1 push = 120 ... padded below
DEF_FUNC px_cb_start_element, 120
    push rbx
    ; Save all three arguments FIRST: px_flush and every helper below
    ; clobbers the caller-saved registers they arrived in.
    mov [rbp - SE_H], rdi
    mov [rbp - SE_RAWNAME], rsi
    mov [rbp - SE_ATTS], rdx
    mov qword [rbp - SE_NAME], 0
    mov qword [rbp - SE_DICT], 0
    mov qword [rbp - SE_ISLIST], 0

    cmp qword [rdi + PxHandle.magic], PX_MAGIC
    jne .out
    cmp qword [gs:ThreadState.current_exception], 0
    jne .out
    ; Every trampoline but the character-data one flushes first, or coalesced
    ; text would arrive after the element that follows it.
    call px_flush
    test eax, eax
    js .out

    mov rdi, [rbp - SE_H]
    mov rsi, [rbp - SE_RAWNAME]
    call px_intern
    test rax, rax
    jz .out
    mov [rbp - SE_NAME], rax

    ; How many attributes there are, which both shapes need and
    ; specified_attributes changes the meaning of.  With that flag set,
    ; libexpat's own count covers only the attributes the DOCUMENT gave --
    ; the ones after it came from defaults in the DTD.
    mov rcx, [rbp - SE_H]
    cmp qword [rcx + PxHandle.specified], 0
    je .count_all
    mov rdi, [rcx + PxHandle.parser]
    call XML_GetSpecifiedAttributeCount wrt ..plt
    movsx rax, eax
    shr rax, 1                  ; libexpat counts array SLOTS, so two per pair
    mov [rbp - SE_N], rax
    jmp .have_count
.count_all:
    mov rax, [rbp - SE_ATTS]
    xor ecx, ecx
    test rax, rax
    jz .counted
.count_loop:
    cmp qword [rax + rcx*8], 0
    je .counted
    add rcx, 2
    jmp .count_loop
.counted:
    shr rcx, 1
    mov [rbp - SE_N], rcx
.have_count:

    ; Two shapes.  `ordered_attributes` asks for a FLAT LIST --
    ; [name, value, name, value, ...] -- and ElementTree sets it and indexes
    ; the result numerically, so a dict there is a KeyError.  Everything else
    ; gets a dict.
    mov rcx, [rbp - SE_H]
    cmp qword [rcx + PxHandle.ordered], 0
    jne .want_list
    call dict_new
    test rax, rax
    jz .out
    mov [rbp - SE_DICT], rax
    jmp .walk
.want_list:
    mov rdi, [rbp - SE_N]
    add rdi, rdi                ; two slots per attribute
    call list_new_filled
    test rax, rax
    jz .out
    mov [rbp - SE_DICT], rax
    mov qword [rbp - SE_ISLIST], 1
    mov rax, [rax + PyListObject.ob_item]   ; a POINTER to the payload array
    mov [rbp - SE_ITEMS], rax

.walk:
    ; Walk the NULL-terminated array of alternating name/value pointers.  The
    ; NAMES are interned and the VALUES are not, which is CPython's split and
    ; not an arbitrary one: a document has few distinct attribute names and
    ; many distinct values.
    mov rbx, [rbp - SE_ATTS]
    mov qword [rbp - SE_AT], 0
    test rbx, rbx
    jz .call
.pair:
    ; Stop at the count rather than at the terminator, so
    ; specified_attributes actually drops the defaulted tail.
    mov rax, [rbp - SE_AT]
    cmp rax, [rbp - SE_N]
    jae .call
    mov rax, [rbx]
    test rax, rax
    jz .call
    mov rdi, [rbp - SE_H]
    mov rsi, rax
    call px_intern              ; the attribute name
    test rax, rax
    jz .out
    mov [rbp - SE_KEY], rax
    mov rdi, [rbx + 8]
    test rdi, rdi
    jz .value_none
    call str_from_cstr_heap     ; the value, NOT interned
    test rax, rax
    jz .drop_key
    jmp .have_value
.value_none:
    lea rax, [rel none_singleton]
    INCREF rax
.have_value:
    cmp qword [rbp - SE_ISLIST], 0
    jne .store_list
    mov rdi, [rbp - SE_DICT]
    mov rsi, [rbp - SE_KEY]
    mov rdx, rax
    push rax
    sub rsp, 8
    call dict_set
    add rsp, 8
    pop rdi
    call obj_decref             ; dict_set took its own reference; the value
                                ;   is a fresh str, so always a pointer
    mov rdi, [rbp - SE_KEY]
    DECREF_V rdi, rcx           ; the KEY is interned: a Value
    jmp .pair_next
.store_list:
    ; The list slots take the references straight over -- no INCREF, no
    ; DECREF: the two were built for this and the list owns them now.
    ;
    ; ob_size is published HERE rather than once at the end, so that an
    ; allocation failure later in the walk releases the pairs already
    ; written: obj_decref on the list frees ob_size items, and a list still
    ; claiming 0 of them freed none.
    mov rcx, [rbp - SE_ITEMS]
    mov rdx, [rbp - SE_AT]
    add rdx, rdx
    mov rsi, [rbp - SE_KEY]
    mov [rcx + rdx*8], rsi
    mov [rcx + rdx*8 + 8], rax
    add rdx, 2
    mov rcx, [rbp - SE_DICT]
    mov [rcx + PyListObject.ob_size], rdx
.pair_next:
    inc qword [rbp - SE_AT]
    add rbx, 16
    jmp .pair
.drop_key:
    mov rdi, [rbp - SE_KEY]
    DECREF_V rdi, rcx
    jmp .out

.call:
    ; ob_size is already right: .store_list publishes it per pair, which is
    ; what makes the failure paths release correctly.  list_new_filled leaves
    ; it at 0 and the caller sets it -- that is its whole contract -- so a walk
    ; that stopped early publishes only what it wrote.
.args:
    mov rax, [rbp - SE_NAME]
    mov [rbp - SE_ARGS], rax
    mov rax, [rbp - SE_DICT]
    mov [rbp - SE_ARGS + 8], rax
    mov rdi, [rbp - SE_H]
    mov esi, PX_H_START_ELEMENT
    lea rdx, [rbp - SE_ARGS]
    mov ecx, 2
    call px_call
    test rax, rax
    jz .out
    mov rdi, rax
    DECREF_V rdi, rcx

.out:
    mov rdi, [rbp - SE_NAME]
    test rdi, rdi
    jz .no_name
    DECREF_V rdi, rcx           ; interned: a Value, not necessarily a pointer
.no_name:
    mov rdi, [rbp - SE_DICT]
    test rdi, rdi
    jz .no_dict
    call obj_decref
.no_dict:
    pop rbx
    leave
    ret
END_FUNC px_cb_start_element

;; ============================================================================
;; px_cb_end_element(rdi = userData, rsi = name) -> nothing
;; ============================================================================
EE_H      equ 8
EE_NAME   equ 16
EE_ARGS   equ 24
EE_FRAME  equ 40                ; + 1 push = 48, 16-aligned
DEF_FUNC px_cb_end_element, EE_FRAME
    push rbx
    mov [rbp - EE_H], rdi
    mov rbx, rsi
    mov qword [rbp - EE_NAME], 0

    cmp qword [rdi + PxHandle.magic], PX_MAGIC
    jne .out
    cmp qword [gs:ThreadState.current_exception], 0
    jne .out
    call px_flush
    test eax, eax
    js .out

    mov rdi, [rbp - EE_H]
    mov rsi, rbx
    call px_intern
    test rax, rax
    jz .out
    mov [rbp - EE_NAME], rax
    mov [rbp - EE_ARGS], rax

    mov rdi, [rbp - EE_H]
    mov esi, PX_H_END_ELEMENT
    lea rdx, [rbp - EE_ARGS]
    mov ecx, 1
    call px_call
    test rax, rax
    jz .out
    mov rdi, rax
    DECREF_V rdi, rcx
.out:
    mov rdi, [rbp - EE_NAME]
    test rdi, rdi
    jz .no_name
    DECREF_V rdi, rcx           ; interned: a Value, not necessarily a pointer
.no_name:
    pop rbx
    leave
    ret
END_FUNC px_cb_end_element

;; ============================================================================
;; px_cb_chardata(rdi = userData, rsi = s, edx = len) -> nothing
;;
;; The ONE trampoline that does not flush on entry, because it is what fills
;; the buffer.  While buffer_text is off -- which is the default, and all
;; there is until the buffering commit -- each chunk goes straight to the
;; handler.  `s` is NOT NUL-terminated, which is why this is the only handler
;; that takes a length.
;; ============================================================================
CD_H      equ 8
CD_STR    equ 16
CD_ARGS   equ 24
CD_FRAME  equ 40                ; + 2 pushes = 56 ... padded below
DEF_FUNC px_cb_chardata, 48
    push rbx
    push r12
    mov [rbp - CD_H], rdi
    mov rbx, rsi
    movsx r12, edx
    mov qword [rbp - CD_STR], 0

    cmp qword [rdi + PxHandle.magic], PX_MAGIC
    jne .out
    cmp qword [gs:ThreadState.current_exception], 0
    jne .out

    mov rdi, rbx
    mov rsi, r12
    call str_new_heap           ; counted: s is not NUL-terminated
    test rax, rax
    jz .out
    mov [rbp - CD_STR], rax
    mov [rbp - CD_ARGS], rax

    mov rdi, [rbp - CD_H]
    mov esi, PX_H_CHARACTER_DATA
    lea rdx, [rbp - CD_ARGS]
    mov ecx, 1
    call px_call
    test rax, rax
    jz .out
    mov rdi, rax
    DECREF_V rdi, rcx
.out:
    mov rdi, [rbp - CD_STR]
    test rdi, rdi
    jz .no_str
    call obj_decref
.no_str:
    pop r12
    pop rbx
    leave
    ret
END_FUNC px_cb_chardata

;; ============================================================================
;; px_marshal(rdi = PxHandle*, rsi = const char*[], edx = count,
;;            ecx = intern bitmask, r8 = Value out[]) -> eax = 0, or -1 with
;;            nothing left built
;;
;; The one place a handler's string arguments are turned into Python objects.
;; A NULL `char*` becomes None either way -- Py_BuildValue's "z" rule, which
;; is what CPython uses for every one of these -- and px_intern happens to do
;; the same, including interning the None as a key.
;; ============================================================================
PM_H      equ 8
PM_RAW    equ 16
PM_N      equ 24
PM_MASK   equ 32
PM_OUT    equ 40
PM_I      equ 48
PM_FRAME  equ 64                ; + 0 pushes = 64, 16-aligned
DEF_FUNC px_marshal, PM_FRAME
    mov [rbp - PM_H], rdi
    mov [rbp - PM_RAW], rsi
    mov [rbp - PM_N], rdx
    mov [rbp - PM_MASK], rcx
    mov [rbp - PM_OUT], r8
    mov qword [rbp - PM_I], 0
.next:
    mov rax, [rbp - PM_I]
    cmp rax, [rbp - PM_N]
    jae .done
    mov rcx, [rbp - PM_RAW]
    mov rsi, [rcx + rax*8]
    ; Is this one interned?  bt is exactly the question the mask asks.
    mov rcx, [rbp - PM_MASK]
    bt rcx, rax
    jnc .plain
    mov rdi, [rbp - PM_H]
    call px_intern
    jmp .stored
.plain:
    test rsi, rsi
    jz .as_none
    mov rdi, rsi
    call str_from_cstr_heap
    jmp .stored
.as_none:
    lea rax, [rel none_singleton]
    INCREF rax
.stored:
    test rax, rax
    jz .fail
    mov rcx, [rbp - PM_OUT]
    mov rdx, [rbp - PM_I]
    mov [rcx + rdx*8], rax
    inc qword [rbp - PM_I]
    jmp .next
.done:
    xor eax, eax
    leave
    ret
.fail:
    ; Release what was built, so a failure leaves nothing behind.
    mov rdi, [rbp - PM_OUT]
    mov rsi, [rbp - PM_I]
    call px_release
    mov eax, -1
    leave
    ret
END_FUNC px_marshal

;; ============================================================================
;; px_release(rdi = Value[], esi = count) -> nothing
;;
;; Drops a marshalled argument array.  The trampolines hand their arguments to
;; px_call and then release them whatever happened, because obj_call_n borrows
;; them.
;; ============================================================================
PR_ARR   equ 8
PR_N     equ 16
PR_I     equ 24
PR_FRAME equ 32                 ; + 0 pushes = 32, 16-aligned
DEF_FUNC px_release, PR_FRAME
    mov [rbp - PR_ARR], rdi
    mov [rbp - PR_N], rsi
    mov qword [rbp - PR_I], 0
.next:
    mov rax, [rbp - PR_I]
    cmp rax, [rbp - PR_N]
    jae .done
    mov rcx, [rbp - PR_ARR]
    mov rdi, [rcx + rax*8]
    test rdi, rdi
    jz .skip
    DECREF_V rdi, rcx
.skip:
    inc qword [rbp - PR_I]
    jmp .next
.done:
    leave
    ret
END_FUNC px_release

;; ============================================================================
;; The uniform trampolines.
;;
;; Each is one line because the bodies differ only in how many strings arrive
;; and which of them are interned.  The interning split is CPython's:
;; a processing instruction's TARGET repeats and its DATA does not; a comment's
;; text never repeats at all.
;; ============================================================================
    PX_CB_STR px_cb_processing_instr, PX_H_PROCESSING_INSTR, 2, 0x1
    PX_CB_STR px_cb_comment,          PX_H_COMMENT,          1, 0x0
    PX_CB_STR px_cb_notation_decl,    PX_H_NOTATION_DECL,    4, 0xF
    PX_CB_STR px_cb_unparsed_entity,  PX_H_UNPARSED_ENTITY,  5, 0x1F
    PX_CB_STR px_cb_start_ns,         PX_H_START_NS_DECL,    2, 0x3
    PX_CB_STR px_cb_end_ns,           PX_H_END_NS_DECL,      1, 0x1

    PX_CB_STR_INT px_cb_start_doctype, PX_H_START_DOCTYPE_DECL, 3, 0x7
    PX_CB_STR_INT px_cb_xml_decl,      PX_H_XML_DECL,           2, 0x0
    PX_CB_STR_INT px_cb_attlist_decl,  PX_H_ATTLIST_DECL,       4, 0x3
    PX_CB_STR_INT px_cb_skipped_entity, PX_H_SKIPPED_ENTITY,    1, 0x1

    PX_CB_VOID px_cb_start_cdata,  PX_H_START_CDATA
    PX_CB_VOID px_cb_end_cdata,    PX_H_END_CDATA
    PX_CB_VOID px_cb_end_doctype,  PX_H_END_DOCTYPE_DECL
