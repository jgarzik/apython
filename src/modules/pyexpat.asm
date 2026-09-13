; pyexpat.asm - the _pyexpatcore module: libexpat's parser, and nothing else.
;
; This half is called BY PYTHON.  Everything here takes a fixed number of
; positional arguments and answers with an int, a str, a bytes or a tuple,
; exactly as `_zlibcore` does and for the same reasons; `lib/pyexpat.py` is
; the public module and carries the xmlparser object, the 22 handler
; attributes, the flags, the `intern` dict, `ExpatError`, the `errors` and
; `model` submodules and every default.
;
; The OTHER half is `src/modules/pyexpat_cb.asm`, which is called BY LIBEXPAT.
; They are separate files because the two sides disagree on the one rule that
; matters: **`RAISE` is legal here and forbidden there.**  `RAISE` tail-jumps
; into `eval_exception_unwind`, which does `mov rsp, [rel eval_base_rsp]` and
; never returns -- from a trampoline that would abandon every libexpat frame
; in between.
;
; Why a shim at all: in 3.12 there is no fallback for pyexpat.  `xml.etree`
; has no non-expat builder (`SimpleXMLTreeBuilder` was removed in 3.9),
; `xml.sax`'s only parser is `expatreader`, and `xml.dom.minidom`, `plistlib`
; and `xmlrpc.client` all go through it.  Without this module all of them
; raise on import or on first use.
;
; A handle is an INDEX into px_handles, not a pointer -- a pointer would be an
; integer a Python program could forge and libexpat would dereference.  The
; struct's `userData` IS the PxHandle*, which never passes through Python, so
; there is nothing to forge there; the trampolines still check the magic,
; because a use-after-free inside libexpat faults with a plausible struct.

%include "macros.inc"
%include "object.inc"
%include "pyexpat.inc"

ASM_INIT

extern dict_new
extern dict_set
extern module_new
extern str_from_cstr_heap
extern str_new_heap
extern obj_decref
extern obj_incref
extern int_from_i64
extern builtin_func_new
extern ap_malloc
extern ap_free
extern ap_memset
extern obj_as_index
extern raise_exception
extern exc_TypeError_type
extern exc_ValueError_type
extern exc_MemoryError_type
extern tuple_new
extern none_singleton
extern str_type
extern dict_type

extern XML_ParserCreate
extern XML_ParserCreateNS
extern XML_ParserFree
extern XML_SetUserData
extern XML_GetErrorCode
extern XML_GetCurrentLineNumber
extern XML_GetCurrentColumnNumber
extern XML_GetCurrentByteIndex
extern XML_ErrorString
extern XML_ExpatVersion
extern XML_Parse
extern XML_SetEncoding
extern XML_SetStartElementHandler
extern XML_SetEndElementHandler
extern XML_SetCharacterDataHandler
extern XML_SetReturnNSTriplet
extern XML_SetProcessingInstructionHandler
extern XML_SetUnparsedEntityDeclHandler
extern XML_SetNotationDeclHandler
extern XML_SetStartNamespaceDeclHandler
extern XML_SetEndNamespaceDeclHandler
extern XML_SetCommentHandler
extern XML_SetStartCdataSectionHandler
extern XML_SetEndCdataSectionHandler
extern XML_SetStartDoctypeDeclHandler
extern XML_SetEndDoctypeDeclHandler
extern XML_SetXmlDeclHandler
extern XML_SetAttlistDeclHandler
extern XML_SetSkippedEntityHandler

extern px_cb_start_element
extern px_cb_end_element
extern px_cb_chardata
extern px_cb_processing_instr
extern px_cb_unparsed_entity
extern px_cb_notation_decl
extern px_cb_start_ns
extern px_cb_end_ns
extern px_cb_comment
extern px_cb_start_cdata
extern px_cb_end_cdata
extern px_cb_start_doctype
extern px_cb_end_doctype
extern px_cb_xml_decl
extern px_cb_attlist_decl
extern px_cb_skipped_entity
extern px_flush
extern bytes_type
extern bytearray_type
extern type_is_subtype
extern obj_is_true
extern current_exception

section .data
align 8
px_handles:     dq 0            ; PxHandle*[], grown by doubling
px_handle_cap:  dq 0
px_handle_n:    dq 0

section .rodata
align 8
global px_installers
; One row per handler index: the libexpat setter, and our trampoline.  A ZERO
; row means the C side is not written yet -- the reference is still kept on the
; handle and read back from Python, so a later commit fills the row in and
; nothing else changes.  The order is PX_H_* from pyexpat.inc, which is
; CPython's handler_info[] order.
px_installers:
    dq XML_SetStartElementHandler,   px_cb_start_element    ; 0  StartElement
    dq XML_SetEndElementHandler,     px_cb_end_element      ; 1  EndElement
    dq XML_SetProcessingInstructionHandler, px_cb_processing_instr   ; 2  ProcessingInstr
    dq XML_SetCharacterDataHandler,  px_cb_chardata         ; 3  CharacterData
    dq XML_SetUnparsedEntityDeclHandler, px_cb_unparsed_entity    ; 4  UnparsedEntity
    dq XML_SetNotationDeclHandler,      px_cb_notation_decl      ; 5  NotationDecl
    dq XML_SetStartNamespaceDeclHandler, px_cb_start_ns           ; 6  StartNamespace
    dq XML_SetEndNamespaceDeclHandler,  px_cb_end_ns             ; 7  EndNamespace
    dq XML_SetCommentHandler,           px_cb_comment            ; 8  Comment
    dq XML_SetStartCdataSectionHandler, px_cb_start_cdata        ; 9  StartCdata
    dq XML_SetEndCdataSectionHandler,   px_cb_end_cdata          ; 10 EndCdata
    dq 0, 0                                                 ; 11 Default
    dq 0, 0                                                 ; 12 DefaultExpand
    dq 0, 0                                                 ; 13 NotStandalone
    dq 0, 0                                                 ; 14 ExternalEntity
    dq XML_SetStartDoctypeDeclHandler,  px_cb_start_doctype      ; 15 StartDoctype
    dq XML_SetEndDoctypeDeclHandler,    px_cb_end_doctype        ; 16 EndDoctype
    dq 0, 0                                                 ; 17 EntityDecl
    dq XML_SetXmlDeclHandler,           px_cb_xml_decl           ; 18 XmlDecl
    dq 0, 0                                                 ; 19 ElementDecl
    dq XML_SetAttlistDeclHandler,       px_cb_attlist_decl       ; 20 AttlistDecl
    dq XML_SetSkippedEntityHandler,     px_cb_skipped_entity     ; 21 SkippedEntity

px_modname:     db "_pyexpatcore", 0

pn_parser_new:      db "parser_new", 0
pn_parser_free:     db "parser_free", 0
pn_parser_status:   db "parser_status", 0
pn_error_string:    db "ErrorString", 0
pn_set_handler:     db "parser_set_handler", 0
pn_parse:           db "parser_parse", 0
pn_set_flag:        db "parser_set_flag", 0
pn_expat_version:   db "EXPAT_VERSION", 0

px_e_nargs:     db "_pyexpatcore: wrong number of arguments", 0
px_e_handle:    db "_pyexpatcore: stale or invalid handle", 0
px_e_oom:       db "out of memory", 0
px_e_create:    db "failed to create the parser", 0
px_e_encoding:  db "encoding must be a string or None", 0
px_e_sep:       db "namespace_separator must be a one-character string or None", 0
px_e_intern:    db "intern must be a dict or None", 0
px_e_index:     db "_pyexpatcore: handler index out of range", 0
px_e_data:      db "Parse() argument must be str or a bytes-like object", 0
px_e_callable:  db "handler must be callable or None", 0
px_e_flag:      db "_pyexpatcore: unknown flag", 0

; One field of the status tuple: int_from_i64 answers with the old
; (payload, tag) pair, so it needs V_PACK before it can be a tuple item.
; Five identical blocks would be five chances to use the wrong slot.
%macro PX_STORE_INT 1           ; %1 = the item index; rdi = the i64
    call int_from_i64
    V_PACK rax, rdx
    mov rcx, [rbp - PS_ITEMS]
    mov [rcx + %1*8], rax
%endmacro

section .text

;; ============================================================================
;; px_handle_at(rdi = handle index) -> rax = PxHandle*, or raises ValueError
;;
;; Bounds-checked, because the index came from Python, and magic-checked,
;; because a freed slot's memory may have been reused and libexpat
;; dereferences whatever it is handed.
;; ============================================================================
DEF_FUNC px_handle_at
    test rdi, rdi
    js .bad
    cmp rdi, [rel px_handle_n]
    jae .bad
    mov rax, [rel px_handles]
    mov rax, [rax + rdi*8]
    test rax, rax
    jz .bad
    cmp qword [rax + PxHandle.magic], PX_MAGIC
    jne .bad
    leave
    ret
.bad:
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rel px_e_handle]
    call raise_exception
    ud2
END_FUNC px_handle_at

;; ============================================================================
;; px_handle_alloc(rdi = a new PxHandle*) -> rax = its index, or -1
;;
;; A freed slot is reused; the table itself only ever grows.  zc_handle_alloc
;; and hc_handle_alloc are the same function over the same shape.
;; ============================================================================
PA_H     equ 8
PA_CAP   equ 16
PA_FRAME equ 40                 ; + 1 push = 48, 16-aligned
DEF_FUNC_LOCAL px_handle_alloc, PA_FRAME
    push rbx
    mov [rbp - PA_H], rdi
    xor ebx, ebx
.scan:
    cmp rbx, [rel px_handle_n]
    jae .append
    mov rax, [rel px_handles]
    cmp qword [rax + rbx*8], 0
    je .take
    inc rbx
    jmp .scan
.take:
    mov rcx, [rbp - PA_H]
    mov [rax + rbx*8], rcx
    mov rax, rbx
    pop rbx
    leave
    ret
.append:
    mov rax, [rel px_handle_n]
    cmp rax, [rel px_handle_cap]
    jb .have_room
    mov rax, [rel px_handle_cap]
    test rax, rax
    jnz .double
    mov eax, 8
    jmp .grow
.double:
    add rax, rax
.grow:
    mov [rbp - PA_CAP], rax
    mov rdi, [rel px_handles]
    mov rsi, rax
    shl rsi, 3
    extern ap_realloc
    call ap_realloc
    test rax, rax
    jz .fail
    mov [rel px_handles], rax
    mov rcx, [rbp - PA_CAP]
    mov [rel px_handle_cap], rcx
.have_room:
    mov rax, [rel px_handle_n]
    mov rcx, [rel px_handles]
    mov rdx, [rbp - PA_H]
    mov [rcx + rax*8], rdx
    inc qword [rel px_handle_n]
    pop rbx
    leave
    ret
.fail:
    mov rax, -1
    pop rbx
    leave
    ret
END_FUNC px_handle_alloc

;; ============================================================================
;; px_arg_int(rdi = args, rsi = index) -> rax = the int, or raises
;;
;; obj_as_index, not int_to_i64: the latter reads PyIntObject.compact off
;; whatever it is handed, so a str argument had its header read as a number.
;; ============================================================================
DEF_FUNC_BARE px_arg_int
    mov rdi, [rdi + rsi*8]
    V_UNPACK rdi, rdx
    jmp obj_as_index
END_FUNC px_arg_int

;; ============================================================================
;; px_arg_str_or_none(rdi = a Value, rsi = the error message) -> rax = a C
;;     string, or 0 for None; raises TypeError for anything else
;;
;; The C string points INTO the str object, so the caller must keep the Value
;; alive across the libexpat call that reads it.  Every caller here does: the
;; argument array is the interpreter's and outlives the call.
;; ============================================================================
PAS_MSG   equ 8
PAS_FRAME equ 16                ; + 0 pushes = 16, 16-aligned
DEF_FUNC_LOCAL px_arg_str_or_none, PAS_FRAME
    mov [rbp - PAS_MSG], rsi
    lea rax, [rel none_singleton]
    cmp rdi, rax
    je .none
    V_TEST_PTR rdi, rax
    ja .bad
    test rdi, rdi
    jz .none
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    jne .bad
    lea rax, [rdi + PyStrObject.data]
    leave
    ret
.none:
    xor eax, eax
    leave
    ret
.bad:
    lea rdi, [rel exc_TypeError_type]
    mov rsi, [rbp - PAS_MSG]
    call raise_exception
    ud2
END_FUNC px_arg_str_or_none

;; ============================================================================
;; _pyexpatcore.parser_new(encoding, namespace_separator, intern) -> int
;;
;; encoding is a str or None; namespace_separator is a one-character str or
;; None, and its PRESENCE is what chooses XML_ParserCreateNS over
;; XML_ParserCreate; intern is a dict or None, and is kept so the trampolines
;; can intern names into it without crossing back into Python.
;;
;; `and rsp, -16` for the reason zc_stream_feed's docblock records: a builtin
;; is reached from func_call at BOTH parities, libexpat is built -O2 and
;; stores to its own frame with aligned SSE, and the symptom would be a
;; general protection fault inside the library rather than a wrong answer.
;; ============================================================================
PN_ARGS   equ 8
PN_H      equ 16
PN_ENC    equ 24
PN_SEP    equ 32
PN_INTERN equ 40
PN_FRAME  equ 56                ; + 1 push = 64, 16-aligned
DEF_FUNC px_parser_new, PN_FRAME
    push rbx
    mov rbx, rsp
    and rsp, -16
    mov [rbp - PN_ARGS], rdi
    cmp rsi, 3
    jne .nargs

    mov rdi, [rdi]
    lea rsi, [rel px_e_encoding]
    call px_arg_str_or_none
    mov [rbp - PN_ENC], rax

    ; The separator: a one-character str, or None for the non-NS parser.
    mov rdi, [rbp - PN_ARGS]
    mov rdi, [rdi + 8]
    lea rsi, [rel px_e_sep]
    call px_arg_str_or_none
    test rax, rax
    jz .no_sep
    ; At most one character, and ASCII: libexpat takes an XML_Char, so a
    ; multi-byte separator cannot be expressed and must be refused rather than
    ; truncated.  An EMPTY one is legal, and is not the same as None -- it
    ; still builds a namespace-aware parser, joining uri and local name with a
    ; NUL byte, which is what CPython does.
    mov rdi, [rbp - PN_ARGS]
    mov rdi, [rdi + 8]
    mov rcx, [rdi + PyStrObject.ob_size]
    test rcx, rcx
    jz .nul_sep
    cmp rcx, 1
    jne .bad_sep
    movzx ecx, byte [rax]
    mov [rbp - PN_SEP], rcx
    jmp .have_sep
.nul_sep:
    mov qword [rbp - PN_SEP], 0
    jmp .have_sep
.no_sep:
    mov qword [rbp - PN_SEP], -1    ; -1 means "no separator"
.have_sep:

    ; intern: a dict or None.
    mov rdi, [rbp - PN_ARGS]
    mov rdi, [rdi + 16]
    lea rax, [rel none_singleton]
    cmp rdi, rax
    je .no_intern
    V_TEST_PTR rdi, rax
    ja .bad_intern
    test rdi, rdi
    jz .no_intern
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel dict_type]
    cmp rax, rcx
    jne .bad_intern
    mov [rbp - PN_INTERN], rdi
    jmp .have_intern
.no_intern:
    mov qword [rbp - PN_INTERN], 0
.have_intern:

    mov edi, PxHandle_size
    call ap_malloc
    test rax, rax
    jz .oom
    mov [rbp - PN_H], rax
    mov rdi, rax
    xor esi, esi                ; ap_memset is (dst, VAL, N), in that order
    mov edx, PxHandle_size
    call ap_memset

    cmp qword [rbp - PN_SEP], -1
    je .plain
    mov rdi, [rbp - PN_ENC]
    mov rsi, [rbp - PN_SEP]
    call XML_ParserCreateNS wrt ..plt
    jmp .created
.plain:
    mov rdi, [rbp - PN_ENC]
    call XML_ParserCreate wrt ..plt
.created:
    test rax, rax
    jz .create_failed
    mov rcx, [rbp - PN_H]
    mov [rcx + PxHandle.parser], rax

    ; userData is the PxHandle*, which is what every trampoline recovers its
    ; state from.  It never passes through Python.
    mov rdi, rax
    mov rsi, rcx
    call XML_SetUserData wrt ..plt

    mov rcx, [rbp - PN_H]
    mov qword [rcx + PxHandle.magic], PX_MAGIC
    mov qword [rcx + PxHandle.buffer_size], PX_BUFFER_DEFAULT
    mov rax, [rbp - PN_INTERN]
    mov [rcx + PxHandle.intern], rax
    test rax, rax
    jz .no_intern_ref
    mov rdi, rax
    call obj_incref             ; the handle owns its reference
.no_intern_ref:

    mov rdi, [rbp - PN_H]
    call px_handle_alloc
    cmp rax, -1
    je .slot_failed
    mov rdi, rax
    call int_from_i64           ; a (payload, tag) pair, not a Value yet
    mov rsp, rbx
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.slot_failed:
    mov rcx, [rbp - PN_H]
    mov rdi, [rcx + PxHandle.parser]
    call XML_ParserFree wrt ..plt
    mov rcx, [rbp - PN_H]
    mov rdi, [rcx + PxHandle.intern]
    test rdi, rdi
    jz .slot_no_intern
    call obj_decref
.slot_no_intern:
    mov rdi, [rbp - PN_H]
    call ap_free
    jmp .oom
.create_failed:
    mov rdi, [rbp - PN_H]
    call ap_free
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rel px_e_create]
    call raise_exception
    ud2
.oom:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_MemoryError_type]
    lea rsi, [rel px_e_oom]
    call raise_exception
    ud2
.bad_sep:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel px_e_sep]
    call raise_exception
    ud2
.bad_intern:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel px_e_intern]
    call raise_exception
    ud2
.nargs:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel px_e_nargs]
    call raise_exception
    ud2
END_FUNC px_parser_new

;; ============================================================================
;; _pyexpatcore.parser_free(handle) -> None
;;
;; Freeing twice is not an error: `__del__` runs on a path the collector
;; chooses and lib/pyexpat.py cannot always know whether it has already run.
;; The magic is zeroed first, so a stale index cannot be revived even if the
;; block is handed straight back out.
;; ============================================================================
PF_IDX    equ 8
PF_H      equ 16
PF_I      equ 24
PF_FRAME  equ 40                ; + 1 push = 48, 16-aligned
DEF_FUNC px_parser_free, PF_FRAME
    push rbx
    mov rbx, rsp
    and rsp, -16
    cmp rsi, 1
    jne .nargs
    xor esi, esi
    call px_arg_int
    mov [rbp - PF_IDX], rax
    ; Not px_handle_at: that raises, and this must tolerate a stale index.
    test rax, rax
    js .done
    cmp rax, [rel px_handle_n]
    jae .done
    mov rcx, [rel px_handles]
    mov rcx, [rcx + rax*8]
    test rcx, rcx
    jz .done
    cmp qword [rcx + PxHandle.magic], PX_MAGIC
    jne .done
    mov qword [rcx + PxHandle.magic], 0
    mov [rbp - PF_H], rcx

    mov rdi, [rcx + PxHandle.parser]
    test rdi, rdi
    jz .no_parser
    ; XML_ParserFree on a parser left mid-parse is well defined, which is what
    ; makes the abandoned-parse case after a handler raised safe to clean up.
    call XML_ParserFree wrt ..plt
.no_parser:

    ; The handler slots are BORROWED -- see parser_set_handler -- so they are
    ; only cleared, never released.  The intern dict below IS the handle's own,
    ; because a child parser from ExternalEntityParserCreate shares it and
    ; nothing on the Python side is guaranteed to outlive both.
    mov qword [rbp - PF_I], 0
.drop_handlers:
    mov rax, [rbp - PF_I]
    cmp rax, PX_H_COUNT
    jae .handlers_done
    mov rcx, [rbp - PF_H]
    mov qword [rcx + PxHandle.handlers + rax*8], 0
    inc qword [rbp - PF_I]
    jmp .drop_handlers
.handlers_done:

    mov rcx, [rbp - PF_H]
    mov rdi, [rcx + PxHandle.intern]
    test rdi, rdi
    jz .no_intern
    mov qword [rcx + PxHandle.intern], 0
    call obj_decref
.no_intern:
    mov rcx, [rbp - PF_H]
    mov rdi, [rcx + PxHandle.buffer]
    test rdi, rdi
    jz .no_buffer
    mov qword [rcx + PxHandle.buffer], 0
    call ap_free
.no_buffer:
    mov rdi, [rbp - PF_H]
    call ap_free
    ; Clear the slot so it can be reused.
    mov rax, [rbp - PF_IDX]
    mov rcx, [rel px_handles]
    mov qword [rcx + rax*8], 0
.done:
    mov rsp, rbx
    pop rbx
    lea rax, [rel none_singleton]
    INCREF rax
    leave
    ret
.nargs:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel px_e_nargs]
    call raise_exception
    ud2
END_FUNC px_parser_free

;; ============================================================================
;; _pyexpatcore.parser_status(handle)
;;     -> (code, lineno, column, byteindex, buffer_used)
;;
;; ONE entry for seven Python attributes, and not as a shortcut.  expat.h has
;;
;;     #define XML_GetErrorLineNumber XML_GetCurrentLineNumber
;;
;; so `XML_GetErrorLineNumber` is NOT a linkable symbol -- there are only the
;; four Current* getters, and `ErrorLineNumber`/`ErrorColumnNumber`/
;; `ErrorByteIndex` are the same numbers read at a different time.  So the
;; Python side reads all of them at once and decides which name to answer
;; with.
;; ============================================================================
PS_H      equ 8
PS_TUP    equ 16
PS_ITEMS  equ 24
PS_FRAME  equ 40                ; + 1 push = 48, 16-aligned
DEF_FUNC px_parser_status, PS_FRAME
    push rbx
    mov rbx, rsp
    and rsp, -16
    cmp rsi, 1
    jne .nargs
    xor esi, esi
    call px_arg_int
    mov rdi, rax
    call px_handle_at
    mov [rbp - PS_H], rax

    mov edi, 5
    call tuple_new
    test rax, rax
    jz .oom
    mov [rbp - PS_TUP], rax
    mov rax, [rax + PyTupleObject.ob_item]  ; a POINTER to the payload array
    mov [rbp - PS_ITEMS], rax

    mov rcx, [rbp - PS_H]
    mov rdi, [rcx + PxHandle.parser]
    call XML_GetErrorCode wrt ..plt
    movsx rdi, eax
    PX_STORE_INT 0

    mov rcx, [rbp - PS_H]
    mov rdi, [rcx + PxHandle.parser]
    call XML_GetCurrentLineNumber wrt ..plt
    mov rdi, rax
    PX_STORE_INT 1

    mov rcx, [rbp - PS_H]
    mov rdi, [rcx + PxHandle.parser]
    call XML_GetCurrentColumnNumber wrt ..plt
    mov rdi, rax
    PX_STORE_INT 2

    mov rcx, [rbp - PS_H]
    mov rdi, [rcx + PxHandle.parser]
    call XML_GetCurrentByteIndex wrt ..plt
    mov rdi, rax
    PX_STORE_INT 3

    mov rcx, [rbp - PS_H]
    mov rdi, [rcx + PxHandle.buffer_used]
    PX_STORE_INT 4

    mov rax, [rbp - PS_TUP]
    mov rsp, rbx
    pop rbx
    leave
    ret
.oom:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_MemoryError_type]
    lea rsi, [rel px_e_oom]
    call raise_exception
    ud2
.nargs:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel px_e_nargs]
    call raise_exception
    ud2
END_FUNC px_parser_status

;; ============================================================================
;; _pyexpatcore.ErrorString(code) -> str, or None for a code expat does not
;;     know
;;
;; From the LIBRARY, not from a table compiled in here: lib/pyexpat.py builds
;; `errors.messages` out of this, so the messages a program sees are the ones
;; the linked expat actually produces.  CPython's add_error does the same and
;; for the same reason.
;; ============================================================================
ES_FRAME equ 24                 ; + 1 push = 32, 16-aligned
DEF_FUNC px_error_string, ES_FRAME
    push rbx
    mov rbx, rsp
    and rsp, -16
    cmp rsi, 1
    jne .nargs
    xor esi, esi
    call px_arg_int
    mov edi, eax
    call XML_ErrorString wrt ..plt
    test rax, rax
    jz .none
    mov rdi, rax
    call str_from_cstr_heap
    mov rsp, rbx
    pop rbx
    leave
    ret
.none:
    mov rsp, rbx
    pop rbx
    lea rax, [rel none_singleton]
    INCREF rax
    leave
    ret
.nargs:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel px_e_nargs]
    call raise_exception
    ud2
END_FUNC px_error_string

;; ============================================================================
;; pyexpat_module_create() -> the _pyexpatcore module object
;; ============================================================================
PM_FRAME equ 24                 ; + 3 pushes = 48, 16-aligned
DEF_FUNC pyexpat_module_create, PM_FRAME
    push rbx
    push r12
    push r13

    call dict_new
    mov r12, rax                ; MODULE_ADD_FUNC reads the dict from r12

    MODULE_ADD_FUNC px_parser_new,    pn_parser_new
    MODULE_ADD_FUNC px_parser_free,   pn_parser_free
    MODULE_ADD_FUNC px_parser_status, pn_parser_status
    MODULE_ADD_FUNC px_error_string,  pn_error_string
    MODULE_ADD_FUNC px_set_handler,   pn_set_handler
    MODULE_ADD_FUNC px_parse,         pn_parse
    MODULE_ADD_FUNC px_set_flag,      pn_set_flag

    ; EXPAT_VERSION comes from the library that is actually linked, not from a
    ; constant compiled in here: `version_info` is parsed out of it in Python,
    ; so a program that logs either sees the truth.
    lea rdi, [rel pn_expat_version]
    call str_from_cstr_heap
    mov rbx, rax
    call XML_ExpatVersion wrt ..plt
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

    lea rdi, [rel px_modname]
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
END_FUNC pyexpat_module_create

;; ============================================================================
;; _pyexpatcore.parser_set_handler(handle, index, fn) -> None
;;
;; `fn` is a callable or None.  The handle takes a reference for CALLING; the
;; Python side keeps its own for reading back, and both are deliberate -- see
;; lib/pyexpat.py's header.
;;
;; Installing the trampoline is what makes libexpat call us, and it is done
;; per handler rather than all at once so that a document with no comments
;; pays nothing for CommentHandler.  A handler with no row in px_installers
;; yet is still stored, so the attribute reads back correctly and a later
;; commit only has to fill the row in.
;; ============================================================================
SH_ARGS   equ 8
SH_H      equ 16
SH_IDX    equ 24
SH_FN     equ 32
SH_ROW    equ 40
SH_FRAME  equ 48                ; + 1 push = 56 ... padded below
DEF_FUNC px_set_handler, 56
    push rbx
    mov rbx, rsp
    and rsp, -16
    mov [rbp - SH_ARGS], rdi
    cmp rsi, 3
    jne .nargs

    xor esi, esi
    call px_arg_int
    mov rdi, rax
    call px_handle_at
    mov [rbp - SH_H], rax

    mov rdi, [rbp - SH_ARGS]
    mov esi, 1
    call px_arg_int
    test rax, rax
    js .bad_index
    cmp rax, PX_H_COUNT
    jae .bad_index
    mov [rbp - SH_IDX], rax

    mov rdi, [rbp - SH_ARGS]
    mov rdi, [rdi + 16]
    lea rax, [rel none_singleton]
    cmp rdi, rax
    je .clearing
    mov [rbp - SH_FN], rdi
    jmp .have_fn
.clearing:
    mov qword [rbp - SH_FN], 0
.have_fn:

    ; The handle BORROWS; lib/pyexpat.py's _handlers list owns.
    ;
    ; This is not a shortcut, it is the only arrangement that works.  An
    ; OWNING reference here is invisible to the collector -- a PxHandle is a
    ; malloc'd struct in a .data table, not a traversable object -- so it made
    ; every parser -> bound method -> parser cycle look externally reachable,
    ; and none of them were ever collected.  Measured: the shape all five
    ; stdlib consumers build leaked 11.6 kB per parser.  CPython can afford to
    ; own its 22 references because its xmlparseobject has a tp_traverse that
    ; visits them; there is nothing here for one to hang off.
    ;
    ; The Python side assigns its list AFTER this returns, so at every instant
    ; the pointer stored here is to an object something else owns: on the way
    ; in, the caller's own reference; on the way out, the list's.
    mov rcx, [rbp - SH_H]
    mov rax, [rbp - SH_IDX]
    mov rdx, [rbp - SH_FN]
    mov [rcx + PxHandle.handlers + rax*8], rdx

    ; The character-data handler is the one whose REMOVAL has to flush first,
    ; or text already coalesced is dropped on the floor.
    cmp qword [rbp - SH_IDX], PX_H_CHARACTER_DATA
    jne .install
    mov rdi, [rbp - SH_H]
    call px_flush
.install:
    ; A row is two qwords, and x86 has no *16 scale -- only 1, 2, 4 and 8 --
    ; so the index is shifted rather than scaled.
    mov rax, [rbp - SH_IDX]
    shl rax, 4
    lea rcx, [rel px_installers]
    add rcx, rax
    mov rdx, [rcx]                  ; the libexpat setter
    test rdx, rdx
    jz .done                        ; no C side yet; the reference is kept
    mov [rbp - SH_ROW], rcx
    mov rcx, [rbp - SH_H]
    mov rdi, [rcx + PxHandle.parser]
    cmp qword [rbp - SH_FN], 0
    je .uninstall
    mov rcx, [rbp - SH_ROW]
    mov rsi, [rcx + 8]              ; our trampoline
    call rdx
    jmp .done
.uninstall:
    xor esi, esi
    call rdx
.done:
    mov rsp, rbx
    pop rbx
    lea rax, [rel none_singleton]
    INCREF rax
    leave
    ret
.bad_index:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rel px_e_index]
    call raise_exception
    ud2
.nargs:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel px_e_nargs]
    call raise_exception
    ud2
END_FUNC px_set_handler

;; ============================================================================
;; _pyexpatcore.parser_parse(handle, data, isfinal) -> 1, 0, or NULL
;;
;; THREE return values, and they are three different things.  This is the one
;; place the zlib precedent -- core raises ValueError, Python converts to
;; `zlib.error` -- would be actively wrong, because USER CODE RUNS INSIDE THIS
;; CALL:
;;
;;   int 1   XML_STATUS_OK, and the post-parse flush also succeeded.
;;   int 0   libexpat reported an error and NOTHING is pending.  lib/pyexpat.py
;;           then reads parser_status and raises ExpatError itself.
;;   NULL    a HANDLER raised.  The exception is already pending; the Python
;;           half returns and lets it propagate untouched.
;;
;; A converting `except ValueError:` in lib/pyexpat.py would have swallowed a
;; handler's own ValueError -- and `plistlib`'s handler raises
;; InvalidFileException, `expatreader`'s raise SAXException, ElementTree's
;; target raises ParseError.  The int-0/NULL split keeps the two channels apart
;; with no exception-type inspection anywhere.  It is also `pyexpat.c`'s order:
;; its `if (PyErr_Occurred()) return NULL;` comes BEFORE its `if (rv == 0)`.
;;
;; A str argument is used in place -- PyStrObject.data is NUL-terminated UTF-8
;; and ob_size is its BYTE length -- with XML_SetEncoding(p, "utf-8") called
;; first, as pyexpat.c does.  Encoding it in Python instead would copy every
;; chunk and put the SetEncoding in the wrong place.
;; ============================================================================
PP_ARGS   equ 8
PP_H      equ 16
PP_DATA   equ 24
PP_LEN    equ 32
PP_FINAL  equ 40
PP_SAVED  equ 48            ; rsp before `and rsp, -16`
PP_STATUS equ 56            ; what XML_Parse answered
PP_FRAME  equ 64            ; + 0 pushes = 64, 16-aligned
DEF_FUNC px_parse, PP_FRAME
    ; The saved rsp goes in a FRAME SLOT, not in a callee-saved register: the
    ; obvious `push rbx / mov rbx, rsp` then wants rbx for the status too, and
    ; using it for both restored rsp to 1 on the way out.  An rbp-relative
    ; slot survives `and rsp, -16` and cannot be wanted for anything else.
    mov [rbp - PP_SAVED], rsp
    and rsp, -16
    mov [rbp - PP_ARGS], rdi
    cmp rsi, 3
    jne .nargs

    xor esi, esi
    call px_arg_int
    mov rdi, rax
    call px_handle_at
    mov [rbp - PP_H], rax
    mov qword [rax + PxHandle.raised], 0

    ; str, bytes or bytearray.  The discrimination is a V_TEST_PTR and three
    ; type compares, never an int_to_i64.
    mov rdi, [rbp - PP_ARGS]
    mov rdi, [rdi + 8]
    V_TEST_PTR rdi, rax
    ja .bad_data
    test rdi, rdi
    jz .bad_data
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    je .is_str
    lea rcx, [rel bytes_type]
    cmp rax, rcx
    je .is_bytes
    lea rcx, [rel bytearray_type]
    cmp rax, rcx
    je .is_bytearray
    ; A subclass of any of the three is still usable, and the layout is the
    ; base's: str and bytes keep their data inline and a subclass's dict goes
    ; at the TAIL for exactly that reason.
    mov rdi, rax
    lea rsi, [rel str_type]
    call type_is_subtype
    test eax, eax
    jnz .sub_str
    mov rdi, [rbp - PP_ARGS]
    mov rdi, [rdi + 8]
    mov rdi, [rdi + PyObject.ob_type]
    lea rsi, [rel bytes_type]
    call type_is_subtype
    test eax, eax
    jnz .sub_bytes
    mov rdi, [rbp - PP_ARGS]
    mov rdi, [rdi + 8]
    mov rdi, [rdi + PyObject.ob_type]
    lea rsi, [rel bytearray_type]
    call type_is_subtype
    test eax, eax
    jnz .sub_bytearray
    jmp .bad_data
.sub_str:
    mov rdi, [rbp - PP_ARGS]
    mov rdi, [rdi + 8]
.is_str:
    mov rax, [rdi + PyStrObject.ob_size]    ; BYTES, not code points
    mov [rbp - PP_LEN], rax
    lea rax, [rdi + PyStrObject.data]
    mov [rbp - PP_DATA], rax
    ; A str is UTF-8 here whatever the document declares, so say so before
    ; feeding it; pyexpat.c does the same and ignores the return.
    mov rcx, [rbp - PP_H]
    mov rdi, [rcx + PxHandle.parser]
    CSTRING rsi, "utf-8"
    call XML_SetEncoding wrt ..plt
    jmp .feed
.sub_bytes:
    mov rdi, [rbp - PP_ARGS]
    mov rdi, [rdi + 8]
.is_bytes:
    mov rax, [rdi + PyBytesObject.ob_size]
    mov [rbp - PP_LEN], rax
    lea rax, [rdi + PyBytesObject.data]
    mov [rbp - PP_DATA], rax
    jmp .feed
.sub_bytearray:
    mov rdi, [rbp - PP_ARGS]
    mov rdi, [rdi + 8]
.is_bytearray:
    mov rax, [rdi + PyByteArrayObject.ob_size]
    mov [rbp - PP_LEN], rax
    mov rax, [rdi + PyByteArrayObject.ob_bytes]
    mov [rbp - PP_DATA], rax

.feed:
    ; isfinal is any object at all -- CPython runs it through the ordinary
    ; truth test -- and obj_is_true takes a VALUE.  This used to V_UNPACK
    ; first, which handed it the raw payload: a bool, None and a str are
    ; pointers and a pointer is its own Value, so those worked, while an int
    ; immediate's payload is the number and `Parse(data, 0)` dereferenced
    ; address 0.  Every caller in the stdlib passes a bool, which is why it
    ; took a hand-written int to find it.
    mov rdi, [rbp - PP_ARGS]
    mov rdi, [rdi + 16]
    call obj_is_true
    mov [rbp - PP_FINAL], rax

    mov rcx, [rbp - PP_H]
    mov rdi, [rcx + PxHandle.parser]
    mov rsi, [rbp - PP_DATA]
    mov edx, [rbp - PP_LEN]
    mov ecx, [rbp - PP_FINAL]
    call XML_Parse wrt ..plt
    mov [rbp - PP_STATUS], rax

    ; The order is pyexpat.c's get_parse_result: a pending exception wins over
    ; whatever libexpat thought of the document.
    cmp qword [rel current_exception], 0
    jne .pending
    cmp dword [rbp - PP_STATUS], 0
    je .expat_error

    mov rdi, [rbp - PP_H]
    call px_flush               ; the post-parse flush can itself raise
    test eax, eax
    js .pending

    mov edi, 1
    call int_from_i64
    jmp .ret_int
.expat_error:
    xor edi, edi
    call int_from_i64
.ret_int:
    mov rsp, [rbp - PP_SAVED]
    leave
    V_PACK rax, rdx
    ret
.pending:
    ; NULL, with the handler's exception intact.  op_call's cleanup sees the 0
    ; and propagates whatever is pending; nothing here inspects it.
    mov rsp, [rbp - PP_SAVED]
    xor eax, eax
    leave
    ret
.bad_data:
    mov rsp, [rbp - PP_SAVED]
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel px_e_data]
    call raise_exception
    ud2
.nargs:
    mov rsp, [rbp - PP_SAVED]
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel px_e_nargs]
    call raise_exception
    ud2
END_FUNC px_parse

;; ============================================================================
;; _pyexpatcore.parser_set_flag(handle, which, value) -> None
;;
;; The three flags the CALLBACKS read -- ordered_attributes,
;; specified_attributes and namespace_prefixes -- live on the handle, because
;; the trampolines consult them while building their arguments and must not
;; cross back into Python to ask.  lib/pyexpat.py keeps its own copy so the
;; attribute reads back as a real bool.
;;
;; namespace_prefixes is the one with a libexpat side:
;; XML_SetReturnNSTriplet makes a namespaced name arrive as
;; "uri<sep>local<sep>prefix" instead of "uri<sep>local".
;;
;; buffer_text and buffer_size arrive here too, and land on the handle for the
;; coalescing commit to use; setting them changes nothing yet.
;; ============================================================================
SF_ARGS   equ 8
SF_H      equ 16
SF_WHICH  equ 24
SF_VALUE  equ 32
SF_SAVED  equ 40
SF_FRAME  equ 48                ; + 0 pushes = 48, 16-aligned
DEF_FUNC px_set_flag, SF_FRAME
    mov [rbp - SF_SAVED], rsp
    and rsp, -16
    mov [rbp - SF_ARGS], rdi
    cmp rsi, 3
    jne .nargs

    xor esi, esi
    call px_arg_int
    mov rdi, rax
    call px_handle_at
    mov [rbp - SF_H], rax

    mov rdi, [rbp - SF_ARGS]
    mov esi, 1
    call px_arg_int
    test rax, rax
    js .bad_flag
    cmp rax, PX_F_COUNT
    jae .bad_flag
    mov [rbp - SF_WHICH], rax

    mov rdi, [rbp - SF_ARGS]
    mov esi, 2
    call px_arg_int
    mov [rbp - SF_VALUE], rax

    mov rcx, [rbp - SF_H]
    mov rax, [rbp - SF_WHICH]
    cmp rax, PX_F_ORDERED
    je .ordered
    cmp rax, PX_F_SPECIFIED
    je .specified
    cmp rax, PX_F_NSPREFIX
    je .nsprefix
    cmp rax, PX_F_BUFFERSIZE
    je .buffersize
    ; PX_F_BUFFERTEXT: the buffer itself arrives with the coalescing commit,
    ; so for now turning it on changes nothing and the flag lives only on the
    ; Python side, where it still reads back correctly.
    jmp .done
.ordered:
    mov rax, [rbp - SF_VALUE]
    mov [rcx + PxHandle.ordered], rax
    jmp .done
.specified:
    mov rax, [rbp - SF_VALUE]
    mov [rcx + PxHandle.specified], rax
    jmp .done
.buffersize:
    mov rax, [rbp - SF_VALUE]
    mov [rcx + PxHandle.buffer_size], rax
    jmp .done
.nsprefix:
    mov rax, [rbp - SF_VALUE]
    mov [rcx + PxHandle.nsprefixes], rax
    mov rdi, [rcx + PxHandle.parser]
    mov rsi, rax
    test rsi, rsi
    jz .triplet
    mov esi, 1                  ; XML_TRUE
.triplet:
    call XML_SetReturnNSTriplet wrt ..plt
.done:
    mov rsp, [rbp - SF_SAVED]
    lea rax, [rel none_singleton]
    INCREF rax
    leave
    ret
.bad_flag:
    mov rsp, [rbp - SF_SAVED]
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rel px_e_flag]
    call raise_exception
    ud2
.nargs:
    mov rsp, [rbp - SF_SAVED]
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel px_e_nargs]
    call raise_exception
    ud2
END_FUNC px_set_flag
