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
; They are separate files because the two sides differ in the one thing that
; matters: who is underneath.  Neither jumps into `eval_exception_unwind` --
; that does `mov rsp, [gs:ThreadState.eval_base_rsp]` and never returns, and
; from a trampoline it would abandon every libexpat frame in between.  This
; half records its refusal and returns 0 to the interpreter, which looks; the
; other half returns to libexpat, which does not, so there a failure is also
; noted on the handle and the parse is stopped.
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

extern dict_set_str
extern dict_new
extern dict_set
extern module_new
extern str_from_cstr_heap
extern str_new_heap
extern obj_decref
extern obj_dealloc
extern obj_incref
extern int_from_i64
extern builtin_func_new
extern ap_malloc
extern ap_free
extern ap_memset
extern malloc
extern free
extern dlsym
extern obj_as_index
extern set_exception
extern exc_TypeError_type
extern exc_ValueError_type
extern exc_MemoryError_type
extern exc_OverflowError_type
extern tuple_new
extern none_singleton
extern bool_true
extern bool_false
extern str_type
extern dict_type
extern list_type

extern XML_ParserCreate
extern XML_ParserCreateNS
extern XML_ExternalEntityParserCreate
extern XML_ParserFree
extern XML_SetUserData
extern XML_SetUnknownEncodingHandler
extern XML_GetErrorCode
extern XML_GetCurrentLineNumber
extern XML_GetCurrentColumnNumber
extern XML_GetCurrentByteIndex
extern XML_ErrorString
extern XML_ExpatVersion
extern XML_Parse
extern XML_SetEncoding
extern XML_SetParamEntityParsing
extern XML_UseForeignDTD
extern XML_GetBase
extern XML_SetBase
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
extern XML_SetDefaultHandler
extern XML_SetDefaultHandlerExpand
extern XML_SetNotStandaloneHandler
extern XML_SetExternalEntityRefHandler
extern XML_SetStartDoctypeDeclHandler
extern XML_SetEndDoctypeDeclHandler
extern XML_SetEntityDeclHandler
extern XML_SetXmlDeclHandler
extern XML_SetElementDeclHandler
extern XML_SetAttlistDeclHandler
extern XML_SetSkippedEntityHandler

extern px_cb_start_element
extern px_cb_end_element
extern px_cb_chardata
extern px_cb_encoding
extern px_cb_noop_chardata
extern px_cb_processing_instr
extern px_cb_unparsed_entity
extern px_cb_notation_decl
extern px_cb_start_ns
extern px_cb_end_ns
extern px_cb_comment
extern px_cb_start_cdata
extern px_cb_end_cdata
extern px_cb_default
extern px_cb_default_expand
extern px_cb_not_standalone
extern px_cb_external_entity
extern px_cb_start_doctype
extern px_cb_end_doctype
extern px_cb_entity_decl
extern px_cb_xml_decl
extern px_cb_element_decl
extern px_cb_attlist_decl
extern px_cb_skipped_entity
extern px_flush
extern bytes_type
extern bytearray_type
extern type_is_subtype
extern obj_is_true

section .data
align 8
px_handles:     dq 0            ; PxHandle*[], grown by doubling
px_handle_cap:  dq 0
px_handle_n:    dq 0
px_set_reparse: dq 0            ; optional before Expat 2.6.0

section .rodata
align 8
global px_installers
; One row per handler index: the libexpat setter and our trampoline.
; PX_H_* in pyexpat.inc follows CPython's handler_info[] order.
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
    dq XML_SetDefaultHandler,           px_cb_default            ; 11 Default
    dq XML_SetDefaultHandlerExpand,     px_cb_default_expand     ; 12 DefaultExpand
    dq XML_SetNotStandaloneHandler,     px_cb_not_standalone     ; 13 NotStandalone
    dq XML_SetExternalEntityRefHandler, px_cb_external_entity    ; 14 ExternalEntity
    dq XML_SetStartDoctypeDeclHandler,  px_cb_start_doctype      ; 15 StartDoctype
    dq XML_SetEndDoctypeDeclHandler,    px_cb_end_doctype        ; 16 EndDoctype
    dq XML_SetEntityDeclHandler,        px_cb_entity_decl        ; 17 EntityDecl
    dq XML_SetXmlDeclHandler,           px_cb_xml_decl           ; 18 XmlDecl
    dq XML_SetElementDeclHandler,       px_cb_element_decl       ; 19 ElementDecl
    dq XML_SetAttlistDeclHandler,       px_cb_attlist_decl       ; 20 AttlistDecl
    dq XML_SetSkippedEntityHandler,     px_cb_skipped_entity     ; 21 SkippedEntity

px_modname:     db "_pyexpatcore", 0

pn_parser_new:      db "parser_new", 0
pn_parser_child:    db "parser_child", 0
pn_parser_free:     db "parser_free", 0
pn_parser_status:   db "parser_status", 0
pn_error_string:    db "ErrorString", 0
pn_set_handler:     db "parser_set_handler", 0
pn_parse:           db "parser_parse", 0
pn_set_flag:        db "parser_set_flag", 0
pn_parser_base:     db "parser_base", 0
pn_expat_version:   db "EXPAT_VERSION", 0
px_reparse_symbol:  db "XML_SetReparseDeferralEnabled", 0

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
;; px_handle_at(rdi = handle index) -> rax = PxHandle*; ValueError otherwise
;; Fails: 0
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
    call set_exception          ; it answers 0, which is this one's failure
    leave
    ret
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
;; px_arg_int(rdi = args, rsi = index) -> rax = the int
;; Fails: -1
;;
;; obj_as_index, not int_to_i64: the latter reads PyIntObject.compact off
;; whatever it is handed, so a str argument had its header read as a number.
;; ============================================================================
DEF_FUNC_BARE px_arg_int
    mov rdi, [rdi + rsi*8]
    V_UNPACK rdi, rdx
    sub rsp, 8                  ; a call, so the refusal can be seen
    call obj_as_index           ; err: its -1 and its exception are this one's
    add rsp, 8
    ret
END_FUNC px_arg_int

;; ============================================================================
;; px_arg_str_or_none(rdi = a Value, rsi = the error message) -> rax = a C
;;     string, or 0 for None; TypeError for anything else
;; Fails: 0?
;;
;; The C string points INTO the str object, so the caller must keep the Value
;; alive across the libexpat call that reads it.  Every caller here does: the
;; argument array is the interpreter's and outlives the call.
;; ============================================================================
PAS_MSG   equ 8
PAS_VALUE equ 16
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
    je .string
    mov [rbp - PAS_VALUE], rdi
    mov rdi, rax
    mov rsi, rcx
    call type_is_subtype
    test eax, eax
    jz .bad
    mov rdi, [rbp - PAS_VALUE]     ; str subclasses retain the inline layout
.string:
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
    call set_exception          ; it answers 0, which is this one's failure
    leave
    ret
END_FUNC px_arg_str_or_none

;; ============================================================================
;; _pyexpatcore.parser_new(encoding, namespace_separator, intern[, mapper]) -> int
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
PN_MAPPER equ 48
PN_FRAME  equ 56                ; + 1 push = 64, 16-aligned
DEF_FUNC px_parser_new, PN_FRAME
    push rbx
    mov rbx, rsp
    and rsp, -16
    mov [rbp - PN_ARGS], rdi
    mov qword [rbp - PN_MAPPER], 0
    cmp rsi, 3
    je .encoding
    cmp rsi, 4
    jne .nargs
    mov rax, [rdi + 24]
    lea rcx, [rel none_singleton]
    cmp rax, rcx
    je .encoding
    mov [rbp - PN_MAPPER], rax

.encoding:
    mov rdi, [rdi]
    lea rsi, [rel px_e_encoding]
    call px_arg_str_or_none
    ERR_PENDING .fail
    mov [rbp - PN_ENC], rax

    ; The separator: a one-character str, or None for the non-NS parser.
    mov rdi, [rbp - PN_ARGS]
    mov rdi, [rdi + 8]
    lea rsi, [rel px_e_sep]
    call px_arg_str_or_none
    ERR_PENDING .fail
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
    mov qword [rcx + PxHandle.refs], 1
    mov qword [rcx + PxHandle.buffer_size], PX_BUFFER_DEFAULT
    mov rax, [rbp - PN_MAPPER]
    mov [rcx + PxHandle.encoding_map], rax
    INCREF_V rax, rdx
    mov rax, [rbp - PN_INTERN]
    mov [rcx + PxHandle.intern], rax
    test rax, rax
    jz .no_intern_ref
    mov rdi, rax
    call obj_incref             ; the handle owns its reference
.no_intern_ref:
    mov rdi, [rbp - PN_H]
    call px_register_encoding

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
    mov rdi, [rbp - PN_H]
    call px_handle_release
    jmp .oom
.create_failed:
    mov rdi, [rbp - PN_H]
    call ap_free
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rel px_e_create]
    call set_exception          ; it answers 0, which is this one's failure
    leave
    ret
.oom:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_MemoryError_type]
    lea rsi, [rel px_e_oom]
    call set_exception          ; it answers 0, which is this one's failure
    leave
    ret
.bad_sep:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel px_e_sep]
    call set_exception          ; it answers 0, which is this one's failure
    leave
    ret
.bad_intern:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel px_e_intern]
    call set_exception          ; it answers 0, which is this one's failure
    leave
    ret
.nargs:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel px_e_nargs]
    call set_exception
.fail:
    mov rsp, rbx
    pop rbx
    xor eax, eax
    leave
    ret
END_FUNC px_parser_new

;; px_register_encoding(handle) -> nothing
;; External parsers can inherit the callback address without its data, so
;; register both explicitly on every parser.
DEF_FUNC_LOCAL px_register_encoding
    xor edx, edx
    lea rsi, [rel px_latin1_alias]
    cmp qword [rdi + PxHandle.encoding_map], 0
    je .register
    mov rdx, rdi
    lea rsi, [rel px_cb_encoding]
.register:
    mov rdi, [rdi + PxHandle.parser]
    call XML_SetUnknownEncodingHandler wrt ..plt
    leave
    ret
END_FUNC px_register_encoding

;; px_latin1_alias(rdi = unused, rsi = name, rdx = XML_Encoding*) -> XML_Status
;; Private callers of parser_new can still omit the Python mapper.
DEF_FUNC_BARE px_latin1_alias
    lea rdi, [rel px_iso8859_name]
    xor ecx, ecx
.name:
    mov al, [rsi + rcx]
    or al, 0x20
    cmp al, [rdi + rcx]
    jne .unknown
    inc ecx
    cmp ecx, 7
    jb .name
    cmp byte [rsi + rcx], 0
    jne .unknown
    xor ecx, ecx
.map:
    mov [rdx + rcx*4], ecx
    inc ecx
    cmp ecx, PX_ENCODING_BYTES
    jb .map
    mov qword [rdx + PX_ENCODING_DATA], 0
    mov qword [rdx + PX_ENCODING_DATA + 8], 0     ; convert
    mov qword [rdx + PX_ENCODING_DATA + 16], 0    ; release
    mov eax, XML_STATUS_OK
    ret
.unknown:
    xor eax, eax
    ret
END_FUNC px_latin1_alias

section .rodata
px_iso8859_name: db "iso8859"
section .text

;; ============================================================================
;; px_handle_release(handle) -> nothing
;;
;; Expat keeps a native parent pointer for child parsing and shares the DTD
;; with parameter-entity children. A Python wrapper can die first, so hold
;; the native chain until its last child is freed.
;; ============================================================================
DEF_FUNC_LOCAL px_handle_release
    push rbx
    push r12
    mov rbx, rdi
.release:
    dec qword [rbx + PxHandle.refs]
    jnz .done
    mov r12, [rbx + PxHandle.parent]
    mov rdi, [rbx + PxHandle.parser]
    call XML_ParserFree wrt ..plt
    mov rdi, [rbx + PxHandle.buffer]
    call free wrt ..plt
    mov rdi, [rbx + PxHandle.intern]
    test rdi, rdi
    jz .release_map
    call obj_decref
.release_map:
    mov rdi, [rbx + PxHandle.encoding_map]
    XDECREF_V rdi, rcx
    mov rdi, rbx
    call ap_free
    mov rbx, r12
    test rbx, rbx
    jnz .release
.done:
    pop r12
    pop rbx
    leave
    ret
END_FUNC px_handle_release

;; ============================================================================
;; _pyexpatcore.parser_child(parent, context, encoding, handlers) -> index
;;
;; Expat inherits the parsing context and callbacks. Attach fresh user data
;; and a fresh text buffer. Fill the child's Python-owned list and native
;; borrowed slots together so handler replacement on the parent cannot leave
;; a dangling reference on the child.
;; ============================================================================
EC_ARGS   equ 8
EC_PARENT equ 16
EC_H      equ 24
EC_LIST   equ 32
EC_CONTEXT equ 40
EC_ENCODING equ 48
EC_SAVED  equ 56
EC_INDEX  equ 64
EC_SLOT   equ 72
EC_FRAME  equ 80
DEF_FUNC px_parser_child, EC_FRAME
    mov [rbp - EC_SAVED], rsp
    and rsp, -16
    mov [rbp - EC_ARGS], rdi
    cmp rsi, 4
    jne .nargs

    xor esi, esi
    call px_arg_int
    ERR_M1 .fail
    mov rdi, rax
    call px_handle_at
    ERR_NULL .fail
    mov [rbp - EC_PARENT], rax

    mov rdi, [rbp - EC_ARGS]
    mov rdi, [rdi + 8]
    CSTRING rsi, "context must be a string or None"
    call px_arg_str_or_none
    ERR_PENDING .fail
    mov [rbp - EC_CONTEXT], rax
    mov rdi, [rbp - EC_ARGS]
    mov rdi, [rdi + 16]
    lea rsi, [rel px_e_encoding]
    call px_arg_str_or_none
    ERR_PENDING .fail
    mov [rbp - EC_ENCODING], rax

    mov rcx, [rbp - EC_ARGS]
    mov rcx, [rcx + 24]
    V_TEST_PTR rcx, rax
    ja .bad_list
    test rcx, rcx
    jz .bad_list
    lea rax, [rel list_type]
    cmp [rcx + PyObject.ob_type], rax
    jne .bad_list
    cmp qword [rcx + PyListObject.ob_size], PX_H_COUNT
    jne .bad_list
    mov rcx, [rcx + PyListObject.ob_item]
    mov [rbp - EC_LIST], rcx
    lea rax, [rel none_singleton]
    xor edx, edx
.check_list:
    cmp [rcx + rdx*8], rax
    jne .bad_list
    inc edx
    cmp edx, PX_H_COUNT
    jb .check_list

    mov edi, PxHandle_size
    call ap_malloc
    test rax, rax
    jz .oom
    mov [rbp - EC_H], rax
    mov rdi, rax
    xor esi, esi
    mov edx, PxHandle_size
    call ap_memset

    mov rcx, [rbp - EC_PARENT]
    mov rdi, [rcx + PxHandle.parser]
    mov rsi, [rbp - EC_CONTEXT]
    mov rdx, [rbp - EC_ENCODING]
    call XML_ExternalEntityParserCreate wrt ..plt
    test rax, rax
    jz .create_failed
    mov rdx, [rbp - EC_H]
    mov [rdx + PxHandle.parser], rax
    mov qword [rdx + PxHandle.refs], 1
    mov qword [rdx + PxHandle.magic], PX_MAGIC
    mov rcx, [rbp - EC_PARENT]
    mov [rdx + PxHandle.parent], rcx
    inc qword [rcx + PxHandle.refs]
    mov rax, [rcx + PxHandle.encoding_map]
    mov [rdx + PxHandle.encoding_map], rax
    INCREF_V rax, rdi
    mov rdi, [rcx + PxHandle.intern]
    mov [rdx + PxHandle.intern], rdi
    test rdi, rdi
    jz .copy_options
    INCREF rdi
.copy_options:
    mov rax, [rcx + PxHandle.ordered]
    mov [rdx + PxHandle.ordered], rax
    mov rax, [rcx + PxHandle.specified]
    mov [rdx + PxHandle.specified], rax
    mov rax, [rcx + PxHandle.nsprefixes]
    mov [rdx + PxHandle.nsprefixes], rax
    mov rdi, [rcx + PxHandle.buffer_size]
    mov [rdx + PxHandle.buffer_size], rdi
    cmp qword [rcx + PxHandle.buffer], 0
    je .register
    call malloc wrt ..plt
    test rax, rax
    jz .release
    mov rdx, [rbp - EC_H]
    mov [rdx + PxHandle.buffer], rax
.register:
    mov rsi, [rbp - EC_H]
    mov rdi, [rsi + PxHandle.parser]
    call XML_SetUserData wrt ..plt
    mov rdi, [rbp - EC_H]
    call px_register_encoding
    mov rdi, [rbp - EC_H]
    call px_handle_alloc
    cmp rax, -1
    je .release
    mov [rbp - EC_SLOT], rax

    mov qword [rbp - EC_INDEX], 0
.copy_handler:
    mov rax, [rbp - EC_INDEX]
    mov rcx, [rbp - EC_PARENT]
    mov rdx, [rcx + PxHandle.handlers + rax*8]
    test rdx, rdx
    jz .next_handler
    INCREF_V rdx, rcx
    mov rcx, [rbp - EC_LIST]
    mov [rcx + rax*8], rdx
    dec qword [rel none_singleton + PyObject.ob_refcnt]
    mov rcx, [rbp - EC_H]
    mov [rcx + PxHandle.handlers + rax*8], rdx
    mov rdi, [rcx + PxHandle.parser]
    shl rax, 4
    lea rcx, [rel px_installers]
    mov rsi, [rcx + rax + 8]
    call [rcx + rax]              ; same setter order as CPython's child
.next_handler:
    inc qword [rbp - EC_INDEX]
    cmp qword [rbp - EC_INDEX], PX_H_COUNT
    jb .copy_handler
    mov rdi, [rbp - EC_SLOT]
    call int_from_i64
    V_PACK rax, rdx
    mov rsp, [rbp - EC_SAVED]
    leave
    ret
.release:
    mov rdi, [rbp - EC_H]
    call px_handle_release
    jmp .oom
.create_failed:
    mov rdi, [rbp - EC_H]
    call ap_free
.oom:
    FAIL exc_MemoryError_type, "", .fail
.bad_list:
    FAIL exc_TypeError_type, "parser_child requires an empty handler list", .fail
.nargs:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel px_e_nargs]
    call set_exception
.fail:
    mov rsp, [rbp - EC_SAVED]
    xor eax, eax
    leave
    ret
END_FUNC px_parser_child

;; ============================================================================
;; _pyexpatcore.parser_free(handle) -> None
;;
;; Tolerate a missing handle when a finalizer runs on a partial construction.
;; Remove the table slot before releasing resources that may run Python.
;; ============================================================================
PF_FRAME equ 8                 ; + 1 push = 16, 16-aligned
DEF_FUNC px_parser_free, PF_FRAME
    push rbx
    mov rbx, rsp
    and rsp, -16
    cmp rsi, 1
    jne .nargs
    xor esi, esi
    call px_arg_int
    ERR_M1 .fail
    test rax, rax
    js .done
    cmp rax, [rel px_handle_n]
    jae .done
    mov rdx, [rel px_handles]
    mov rcx, [rdx + rax*8]
    test rcx, rcx
    jz .done
    cmp qword [rcx + PxHandle.magic], PX_MAGIC
    jne .done
    cmp qword [rcx + PxHandle.parsing], 0
    jne .done
    cmp qword [rcx + PxHandle.in_callback], 0
    jne .done
    cmp qword [rcx + PxHandle.flushing], 0
    jne .done
    mov qword [rcx + PxHandle.magic], 0
    mov qword [rdx + rax*8], 0
    mov rdi, rcx
    call px_handle_release
.done:
    mov rsp, rbx
    pop rbx
    lea rax, [rel none_singleton]
    INCREF rax
    leave
    ret
.nargs:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel px_e_nargs]
    call set_exception
.fail:
    mov rsp, rbx
    pop rbx
    xor eax, eax
    leave
    ret
END_FUNC px_parser_free

;; ============================================================================
;; _pyexpatcore.parser_status(handle)
;;     -> (code, lineno, column, byteindex, buffer_used, buffer_size, buffer_text)
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
    ERR_M1 .fail
    mov rdi, rax
    call px_handle_at
    ERR_NULL .fail
    mov [rbp - PS_H], rax

    mov edi, 7
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

    mov rcx, [rbp - PS_H]
    mov rdi, [rcx + PxHandle.buffer_size]
    PX_STORE_INT 5

    mov rcx, [rbp - PS_H]
    lea rax, [rel bool_false]
    lea rdx, [rel bool_true]
    cmp qword [rcx + PxHandle.buffer], 0
    cmovne rax, rdx
    INCREF rax
    mov rcx, [rbp - PS_ITEMS]
    mov [rcx + 6*8], rax

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
    call set_exception          ; it answers 0, which is this one's failure
    leave
    ret
.nargs:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel px_e_nargs]
    call set_exception
.fail:
    mov rsp, rbx
    pop rbx
    xor eax, eax
    leave
    ret
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
    ERR_M1 .fail
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
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel px_e_nargs]
    call set_exception
.fail:
    mov rsp, rbx
    pop rbx
    xor eax, eax
    leave
    ret
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
    MODULE_ADD_FUNC px_parser_child,  pn_parser_child
    MODULE_ADD_FUNC px_parser_free,   pn_parser_free
    MODULE_ADD_FUNC px_parser_status, pn_parser_status
    MODULE_ADD_FUNC px_error_string,  pn_error_string
    MODULE_ADD_FUNC px_set_handler,   pn_set_handler
    MODULE_ADD_FUNC px_parse,         pn_parse
    MODULE_ADD_FUNC px_set_flag,      pn_set_flag
    MODULE_ADD_FUNC px_parser_base,   pn_parser_base

    xor edi, edi                ; RTLD_DEFAULT
    lea rsi, [rel px_reparse_symbol]
    call dlsym wrt ..plt
    mov [rel px_set_reparse], rax

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
    call dict_set_str
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
;; pays nothing for CommentHandler.
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
    ERR_M1 .fail
    mov rdi, rax
    call px_handle_at
    ERR_NULL .fail
    mov [rbp - SH_H], rax

    mov rdi, [rbp - SH_ARGS]
    mov esi, 1
    call px_arg_int
    ERR_M1 .fail
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
    ; Deliver buffered data to the old handler before publishing its replacement.
    cmp qword [rbp - SH_IDX], PX_H_CHARACTER_DATA
    jne .publish
    mov rdi, [rbp - SH_H]
    call px_flush
    test eax, eax
    js .fail
.publish:

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

    ; A row is two qwords, and x86 has no *16 scale -- only 1, 2, 4 and 8 --
    ; so the index is shifted rather than scaled.
    mov rax, [rbp - SH_IDX]
    shl rax, 4
    lea rcx, [rel px_installers]
    add rcx, rax
    mov rdx, [rcx]                  ; the libexpat setter
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
    cmp qword [rbp - SH_IDX], PX_H_CHARACTER_DATA
    jne .uninstall_call
    cmp qword [rcx + PxHandle.in_callback], 0
    je .uninstall_call
    lea rsi, [rel px_cb_noop_chardata]
.uninstall_call:
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
    call set_exception          ; it answers 0, which is this one's failure
    leave
    ret
.nargs:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel px_e_nargs]
    call set_exception
.fail:
    mov rsp, rbx
    pop rbx
    xor eax, eax
    leave
    ret
END_FUNC px_set_handler

;; ============================================================================
;; _pyexpatcore.parser_parse(handle, data, isfinal[, flush]) -> 1, 0, or NULL
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
PP_FLUSH  equ 64            ; ParseFile defers delivery between its reads
PP_FRAME  equ 64            ; + 0 pushes = 64, 16-aligned
DEF_FUNC px_parse, PP_FRAME
    ; The saved rsp goes in a FRAME SLOT, not in a callee-saved register: the
    ; obvious `push rbx / mov rbx, rsp` then wants rbx for the status too, and
    ; using it for both restored rsp to 1 on the way out.  An rbp-relative
    ; slot survives `and rsp, -16` and cannot be wanted for anything else.
    mov [rbp - PP_SAVED], rsp
    and rsp, -16
    mov [rbp - PP_ARGS], rdi
    mov qword [rbp - PP_FLUSH], 1
    cmp rsi, 3
    je .final_arg
    cmp rsi, 4
    jne .nargs
    mov rdi, [rdi + 24]
    call obj_is_true
    ERR_M1 .pending
    mov [rbp - PP_FLUSH], rax
.final_arg:
    ; Truth testing may call Python. Resolve it before borrowing any pointers.
    mov rdi, [rbp - PP_ARGS]
    mov rdi, [rdi + 16]
    call obj_is_true
    ERR_M1 .pending
    mov [rbp - PP_FINAL], rax
    mov rdi, [rbp - PP_ARGS]

    xor esi, esi
    call px_arg_int
    ERR_M1 .pending
    mov rdi, rax
    call px_handle_at
    ERR_NULL .pending
    mov [rbp - PP_H], rax
    cmp qword [rax + PxHandle.parsing], 0
    jne .reentrant
    cmp qword [rax + PxHandle.in_callback], 0
    jne .reentrant
    cmp qword [rax + PxHandle.flushing], 0
    jne .reentrant
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
    mov rcx, [rbp - PP_H]
    mov qword [rcx + PxHandle.parsing], 1
    mov rdi, [rcx + PxHandle.parser]
    mov rsi, [rbp - PP_DATA]
    mov edx, [rbp - PP_LEN]
    mov ecx, [rbp - PP_FINAL]
    call XML_Parse wrt ..plt
    mov [rbp - PP_STATUS], rax
    mov rcx, [rbp - PP_H]
    mov qword [rcx + PxHandle.parsing], 0

    ; The order is pyexpat.c's get_parse_result: a pending exception wins over
    ; whatever libexpat thought of the document.
    cmp qword [gs:ThreadState.current_exception], 0
    jne .pending
    cmp dword [rbp - PP_STATUS], 0
    je .expat_error

    cmp qword [rbp - PP_FLUSH], 0
    je .success
    mov rdi, [rbp - PP_H]
    call px_flush               ; the post-parse flush can itself raise
    test eax, eax
    js .pending

.success:
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
    ; NULL, with the exception intact -- a handler's, or an argument's.  op_call's cleanup sees the 0
    ; and propagates whatever is pending; nothing here inspects it.
    mov rsp, [rbp - PP_SAVED]
    xor eax, eax
    leave
    ret
.reentrant:
    extern exc_RuntimeError_type
    FAIL exc_RuntimeError_type, "cannot parse the same parser from a callback", .pending
.bad_data:
    mov rsp, [rbp - PP_SAVED]
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel px_e_data]
    call set_exception          ; it answers 0, which is this one's failure
    leave
    ret
.nargs:
    mov rsp, [rbp - PP_SAVED]
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel px_e_nargs]
    call set_exception          ; it answers 0, which is this one's failure
    leave
    ret
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
;; Buffer changes finish delivery before replacing the handle's storage.
;; ============================================================================
SF_ARGS   equ 8
SF_H      equ 16
SF_WHICH  equ 24
SF_VALUE  equ 32
SF_SAVED  equ 40
SF_BUFFER equ 48
SF_FRAME  equ 48                ; + 0 pushes = 48, 16-aligned
DEF_FUNC px_set_flag, SF_FRAME
    mov [rbp - SF_SAVED], rsp
    and rsp, -16
    mov [rbp - SF_ARGS], rdi
    cmp rsi, 3
    jne .nargs

    xor esi, esi
    call px_arg_int
    ERR_M1 .fail
    mov rdi, rax
    call px_handle_at
    ERR_NULL .fail
    mov [rbp - SF_H], rax

    mov rdi, [rbp - SF_ARGS]
    mov esi, 1
    call px_arg_int
    ERR_M1 .fail
    test rax, rax
    js .bad_flag
    cmp rax, PX_F_COUNT
    jae .bad_flag
    mov [rbp - SF_WHICH], rax

    mov rdi, [rbp - SF_ARGS]
    mov esi, 2
    call px_arg_int
    ERR_M1 .fail
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
    cmp rax, PX_F_REPARSE
    je .reparse
    cmp rax, PX_F_PARAM_ENTITY
    je .param_entity
    cmp rax, PX_F_FOREIGN_DTD
    je .foreign_dtd
    cmp qword [rbp - SF_VALUE], 0
    je .disable
    cmp qword [rcx + PxHandle.buffer], 0
    jne .done
    mov rax, [rcx + PxHandle.buffer_size]
    mov [rbp - SF_VALUE], rax
    jmp .allocate
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
    test rax, rax
    jle .small_size
    cmp rax, 0x7fffffff
    ja .large_size
    cmp rax, [rcx + PxHandle.buffer_size]
    je .done
.allocate:
    mov rdi, rax
    call malloc wrt ..plt
    test rax, rax
    jz .oom
    mov [rbp - SF_BUFFER], rax
    mov rdi, [rbp - SF_H]
    call px_flush
    test eax, eax
    js .discard_buffer
    mov rcx, [rbp - SF_H]
    mov rax, [rbp - SF_VALUE]
    mov [rcx + PxHandle.buffer_size], rax
    jmp .replace_buffer
.disable:
    cmp qword [rcx + PxHandle.buffer], 0
    je .done
    mov qword [rbp - SF_BUFFER], 0
    mov rdi, rcx
    call px_flush
    test eax, eax
    js .fail
.replace_buffer:
    mov rcx, [rbp - SF_H]          ; the callback may have changed the buffer
    mov rax, [rbp - SF_BUFFER]
    mov rdi, [rcx + PxHandle.buffer]
    mov [rcx + PxHandle.buffer], rax
    mov qword [rcx + PxHandle.buffer_used], 0
    call free wrt ..plt
    jmp .done
.discard_buffer:
    mov rdi, [rbp - SF_BUFFER]
    call free wrt ..plt
    jmp .fail
.small_size:
    FAIL exc_ValueError_type, "buffer_size must be greater than zero", .fail
.large_size:
    FAIL exc_ValueError_type, "buffer_size must not be greater than 2147483647", .fail
.oom:
    FAIL exc_MemoryError_type, "", .fail
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
.reparse:
    mov rax, [rel px_set_reparse]
    test rax, rax
    jz .reparse_disabled
    mov rdi, [rcx + PxHandle.parser]
    xor esi, esi
    cmp qword [rbp - SF_VALUE], 0
    setne sil
    call rax
    cmp qword [rbp - SF_VALUE], 0
    je .reparse_disabled
    lea rax, [rel bool_true]
    jmp .reparse_return
.reparse_disabled:
    lea rax, [rel bool_false]
.reparse_return:
    mov rsp, [rbp - SF_SAVED]
    INCREF rax
    leave
    ret
.param_entity:
    mov rax, [rbp - SF_VALUE]
    movsxd rdx, eax
    cmp rax, rdx
    jne .param_overflow
    mov esi, eax
    mov rdi, [rcx + PxHandle.parser]
    call XML_SetParamEntityParsing wrt ..plt
    jmp .return_int
.foreign_dtd:
    mov rdi, [rcx + PxHandle.parser]
    xor esi, esi
    cmp qword [rbp - SF_VALUE], 0
    setne sil
    call XML_UseForeignDTD wrt ..plt
.return_int:
    movsxd rdi, eax
    call int_from_i64
    V_PACK rax, rdx
    mov rsp, [rbp - SF_SAVED]
    leave
    ret
.param_overflow:
    FAIL exc_OverflowError_type, "Python int too large to convert to C int", .fail
.bad_flag:
    mov rsp, [rbp - SF_SAVED]
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rel px_e_flag]
    call set_exception          ; it answers 0, which is this one's failure
    leave
    ret
.nargs:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel px_e_nargs]
    call set_exception
.fail:
    mov rsp, [rbp - SF_SAVED]
    xor eax, eax
    leave
    ret
END_FUNC px_set_flag

;; _pyexpatcore.parser_base(handle[, base]) -> URL string or None
;; Expat copies the base URL for use in later entity callbacks.
PB_SAVED equ 8
PB_ARGS  equ 16
PB_NARGS equ 24
PB_H     equ 32
PB_FRAME equ 32
DEF_FUNC px_parser_base, PB_FRAME
    mov [rbp - PB_SAVED], rsp
    and rsp, -16
    mov [rbp - PB_ARGS], rdi
    mov [rbp - PB_NARGS], rsi
    cmp rsi, 1
    je .handle
    cmp rsi, 2
    jne .nargs
.handle:
    xor esi, esi
    call px_arg_int
    ERR_M1 .fail
    mov rdi, rax
    call px_handle_at
    ERR_NULL .fail
    mov [rbp - PB_H], rax
    cmp qword [rbp - PB_NARGS], 1
    je .get
    mov rdi, [rbp - PB_ARGS]
    mov rdi, [rdi + 8]
    CSTRING rsi, "base must be a string"
    call px_arg_str_or_none
    ERR_PENDING .fail
    test rax, rax
    jz .bad_base
    mov rsi, rax
    mov rdi, [rbp - PB_H]
    mov rdi, [rdi + PxHandle.parser]
    call XML_SetBase wrt ..plt
    test eax, eax
    jz .oom
    jmp .none
.get:
    mov rdi, [rax + PxHandle.parser]
    call XML_GetBase wrt ..plt
    test rax, rax
    jz .none
    mov rdi, rax
    call str_from_cstr_heap
    test rax, rax
    jz .oom
    jmp .done
.none:
    lea rax, [rel none_singleton]
    INCREF rax
.done:
    mov rsp, [rbp - PB_SAVED]
    leave
    ret
.oom:
    FAIL exc_MemoryError_type, "", .fail
.bad_base:
    FAIL exc_TypeError_type, "base must be a string", .fail
.nargs:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel px_e_nargs]
    call set_exception
.fail:
    mov rsp, [rbp - PB_SAVED]
    xor eax, eax
    leave
    ret
END_FUNC px_parser_base
