; pyexpat.inc - the private ABI the two halves of the pyexpat shim share.
;
; src/modules/pyexpat.asm is called BY Python; src/modules/pyexpat_cb.asm is
; called BY libexpat.  They are separate files because the two sides have
; different ABIs, different alignment rules and -- the reason the seam is real
; rather than cosmetic -- OPPOSITE ERROR DISCIPLINE.  See the header of each.
;
; Everything here is what both need to agree on: the handle, the handler
; index enum and the flag ids.

%ifndef PYEXPAT_INC
%define PYEXPAT_INC

; "PXML".  A freed slot must not read back as live: libexpat dereferences
; whatever it is handed, and a use-after-free there faults inside the library
; with a struct that still looks plausible.  Same reason ZHandle has one.
PX_MAGIC equ 0x50584D4C

; The handler slots, in CPython's `handler_info[]` order (Modules/pyexpat.c).
; That order is the source of truth for this enum AND for the list in
; lib/pyexpat.py, and the two must not drift: the core bounds-checks the index,
; so a mismatch is a wrong handler rather than a wild call -- but a wrong
; handler has no symptom anywhere near its cause.
PX_H_START_ELEMENT       equ 0
PX_H_END_ELEMENT         equ 1
PX_H_PROCESSING_INSTR    equ 2
PX_H_CHARACTER_DATA      equ 3
PX_H_UNPARSED_ENTITY     equ 4
PX_H_NOTATION_DECL       equ 5
PX_H_START_NS_DECL       equ 6
PX_H_END_NS_DECL         equ 7
PX_H_COMMENT             equ 8
PX_H_START_CDATA         equ 9
PX_H_END_CDATA           equ 10
PX_H_DEFAULT             equ 11
PX_H_DEFAULT_EXPAND      equ 12
PX_H_NOT_STANDALONE      equ 13
PX_H_EXTERNAL_ENTITY_REF equ 14
PX_H_START_DOCTYPE_DECL  equ 15
PX_H_END_DOCTYPE_DECL    equ 16
PX_H_ENTITY_DECL         equ 17
PX_H_XML_DECL            equ 18
PX_H_ELEMENT_DECL        equ 19
PX_H_ATTLIST_DECL        equ 20
PX_H_SKIPPED_ENTITY      equ 21
PX_H_COUNT               equ 22

; parser_set_flag's `which`.
PX_F_ORDERED     equ 0          ; ordered_attributes
PX_F_SPECIFIED   equ 1          ; specified_attributes
PX_F_NSPREFIX    equ 2          ; namespace_prefixes
PX_F_BUFFERTEXT  equ 3          ; buffer_text
PX_F_BUFFERSIZE  equ 4          ; buffer_size
PX_F_REPARSE     equ 5          ; SetReparseDeferralEnabled
PX_F_COUNT       equ 6

; CPython's default, and the one test_pyexpat's coalescing cases assume.
PX_BUFFER_DEFAULT equ 8192

; The recursion cap on the XML_Content walk.  The nesting is attacker-supplied
; DTD, and CPython recurses unguarded there; a cap is the smaller divergence
; than running the machine stack into the guard page.
PX_MODEL_DEPTH equ 200

; XML_Status, from expat.h.
XML_STATUS_ERROR     equ 0
XML_STATUS_OK        equ 1
XML_STATUS_SUSPENDED equ 2

; XML_Content, from expat.h, with UTF-8 XML_Char and the SysV C layout.
struc PxContent
    .type:        resd 1
    .quant:       resd 1
    .name:        resq 1
    .numchildren: resd 1
    .padding:     resd 1
    .children:    resq 1
endstruc

struc PxHandle
    .magic:       resq 1
    .parser:      resq 1        ; XML_Parser, opaque: libexpat allocates and
                                ;   frees its own with its own allocator, so
                                ;   there is no struct here to align and the
                                ;   magic can sit first, unlike ZHandle's
    .handlers:    resq PX_H_COUNT   ; owned Values, or 0 for unset
    .intern:      resq 1        ; owned dict, or 0
    .buffer:      resq 1        ; the coalescing buffer, 0 when buffer_text off
    .buffer_size: resq 1
    .buffer_used: resq 1
    .flushing:    resq 1        ; the current block is already being delivered
    .ordered:     resq 1
    .specified:   resq 1
    .nsprefixes:  resq 1
    .parsing:     resq 1        ; XML_Parse has native frames on the stack
    .in_callback: resq 1
    .raised:      resq 1        ; a handler raised; Parse reports it in band
endstruc

%endif ; PYEXPAT_INC
