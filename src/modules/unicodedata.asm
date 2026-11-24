; unicodedata.asm - the `unicodedata` module, over tables the tree already has.
;
; The Unicode character database in CPython is a C module over generated
; tables; here the tables were generated for other reasons and this is the
; module surface over them.  src/compiler/unicodename.asm holds the names
; `\N{...}` resolves and src/compiler/unicodecase.asm the per-character flags
; str.isdecimal() and friends read, both taken from a running CPython by
; `make regen` rather than transcribed.
;
; The property half -- category(), combining(), bidirectional(),
; east_asian_width(), mirrored(), numeric() and digit() -- needed tables
; nothing else in the tree wanted, and src/modules/unicodedataprops.asm is
; those, generated the same way from the same source.  Five of them are
; run-compressed, because the properties are enormously runny: 0x110000 code
; points collapse to 4007 rows for the general category and 229 for mirrored.
;
; decomposition() and normalize() are still absent, and they are the expensive
; pair: canonical AND compatibility decomposition, the composition exclusions
; and the Hangul algorithm.  Absent rather than approximated, so a program
; that needs one gets an AttributeError it can see rather than a confident
; wrong answer.
;
; The module existing at all is most of the value: `import unicodedata` was a
; ModuleNotFoundError, and a test module that imports it dies at collection
; with every one of its tests unrun -- 308 of them across CPython's suite.
; lib/_codecs.py and lib/re/_parser.py reach for lookup() and nothing else.

%include "macros.inc"
%include "object.inc"

extern dict_new
extern dict_set
extern module_new
extern obj_decref
extern str_from_cstr_heap
extern str_new_heap
extern str_cp_at
extern str_type
extern uniname_lookup
extern uniname_name
extern udecimal_value
extern builtin_func_new
extern exc_TypeError_type
extern exc_ValueError_type
extern exc_KeyError_type
extern set_exception
extern int_from_i64
extern obj_incref
extern float_from_f64
extern udp_category_starts
extern udp_category_count
extern udp_category_strings
extern udp_bidi_starts
extern udp_bidi_count
extern udp_bidi_strings
extern udp_eaw_starts
extern udp_eaw_count
extern udp_eaw_strings
extern udp_combining_starts
extern udp_combining_count
extern udp_mirrored_starts
extern udp_mirrored_count
extern udp_digit_table
extern udp_digit_count
extern udp_numeric_table
extern udp_numeric_count

section .text

;; ============================================================================
;; ud_one_codepoint(rdi = a Value) -> rax = the code point, or -1
;;
;; Every one of these functions takes "a character": a str of length exactly
;; one, which is what CPython requires and what it words as
;; "argument 1 must be a unicode character, not str" for anything longer.
;; ============================================================================
DEF_FUNC_LOCAL ud_one_codepoint
    V_TEST_PTR rdi, rax
    ja .udoc_no
    test rdi, rdi
    jz .udoc_no
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    je .udoc_is_str
    ; A str SUBCLASS is a str.  CPython's unicode converter takes one, and an
    ; exact ob_type compare refused every property here for it.
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_STR_SUBCLASS
    jz .udoc_no
.udoc_is_str:
    cmp qword [rdi + PyStrObject.ob_length], 1
    jne .udoc_no
    xor esi, esi
    call str_cp_at
    leave
    ret
.udoc_no:
    mov rax, -1
    leave
    ret
END_FUNC ud_one_codepoint

;; ============================================================================
;; unicodedata.lookup(name) -> the character with that name
;;
;; uniname_lookup is the same search `\N{...}` uses, aliases and the
;; algorithmic CJK family included, and its answer is the same one -- so the
;; two cannot drift.
;; ============================================================================
UDL_BUF   equ 24            ; up to four UTF-8 bytes and a NUL
UDL_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
DEF_FUNC unicodedata_lookup, UDL_FRAME
    cmp rsi, 1
    jne .udl_arity
    mov rdi, [rdi]
    V_TEST_PTR rdi, rax
    ja .udl_type
    test rdi, rdi
    jz .udl_type
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    jne .udl_type
    mov rsi, [rdi + PyStrObject.ob_size]
    lea rdi, [rdi + PyStrObject.data]
    call uniname_lookup
    cmp rax, -1
    je .udl_miss

    ; The code point as a one-character str.  The encoder is written out
    ; rather than borrowed from chr(): chr() takes a Value and raises its own
    ; wording, and this needs neither.
    lea rdx, [rbp - UDL_BUF]
    cmp rax, 0x7f
    ja .udl_two
    mov [rdx], al
    mov esi, 1
    jmp .udl_build
.udl_two:
    cmp rax, 0x7ff
    ja .udl_three
    mov ecx, eax
    shr ecx, 6
    or ecx, 0xc0
    mov [rdx], cl
    and eax, 0x3f
    or eax, 0x80
    mov [rdx + 1], al
    mov esi, 2
    jmp .udl_build
.udl_three:
    cmp rax, 0xffff
    ja .udl_four
    mov ecx, eax
    shr ecx, 12
    or ecx, 0xe0
    mov [rdx], cl
    mov ecx, eax
    shr ecx, 6
    and ecx, 0x3f
    or ecx, 0x80
    mov [rdx + 1], cl
    and eax, 0x3f
    or eax, 0x80
    mov [rdx + 2], al
    mov esi, 3
    jmp .udl_build
.udl_four:
    mov ecx, eax
    shr ecx, 18
    or ecx, 0xf0
    mov [rdx], cl
    mov ecx, eax
    shr ecx, 12
    and ecx, 0x3f
    or ecx, 0x80
    mov [rdx + 1], cl
    mov ecx, eax
    shr ecx, 6
    and ecx, 0x3f
    or ecx, 0x80
    mov [rdx + 2], cl
    and eax, 0x3f
    or eax, 0x80
    mov [rdx + 3], al
    mov esi, 4
.udl_build:
    lea rdi, [rbp - UDL_BUF]
    call str_new_heap
    leave
    ret

.udl_miss:
    SET_EXC exc_KeyError_type, "undefined character name"
    leave                       ; set_exception answered 0
    ret
.udl_type:
    SET_EXC exc_TypeError_type, "lookup() argument must be str"
    leave                       ; set_exception answered 0
    ret
.udl_arity:
    SET_EXC exc_TypeError_type, "lookup() takes exactly one argument"
    leave                       ; set_exception answered 0
    ret
END_FUNC unicodedata_lookup

;; ============================================================================
;; unicodedata.name(chr[, default]) -> the character's name
;;
;; A character with no name is a ValueError, unless a default was given.  An
;; ALIAS is not a name: `lookup('LF')` is U+000A and `name('\n')` raises,
;; which is why uniname_name stops where the aliases begin.
;; ============================================================================
UDN_BUF   equ 152           ; UN_BUFSZ, which uniname_name decodes into
UDN_DEF   equ 160
UDN_FRAME equ 176           ; + 0 pushes = 176, 16-aligned
DEF_FUNC unicodedata_name, UDN_FRAME
    cmp rsi, 1
    jl .udn_arity
    cmp rsi, 2
    jg .udn_arity
    mov qword [rbp - UDN_DEF], 0
    cmp rsi, 2
    jne .udn_no_default
    mov rax, [rdi + 8]
    mov [rbp - UDN_DEF], rax
.udn_no_default:
    mov rdi, [rdi]
    call ud_one_codepoint
    cmp rax, -1
    je .udn_type

    mov rdi, rax
    lea rsi, [rbp - UDN_BUF]
    mov edx, 128
    call uniname_name
    cmp rax, -1
    je .udn_none

    mov rsi, rax
    lea rdi, [rbp - UDN_BUF]
    call str_new_heap
    leave
    ret

.udn_none:
    mov rax, [rbp - UDN_DEF]
    test rax, rax
    jz .udn_no_name
    mov rdi, rax
    INCREF_V rdi, rcx
    mov rax, rdi
    leave
    ret

.udn_no_name:
    SET_EXC exc_ValueError_type, "no such name"
    leave                       ; set_exception answered 0
    ret
.udn_type:
    SET_EXC exc_TypeError_type, "name() argument 1 must be a unicode character"
    leave                       ; set_exception answered 0
    ret
.udn_arity:
    SET_EXC exc_TypeError_type, "name() takes 1 or 2 arguments"
    leave                       ; set_exception answered 0
    ret
END_FUNC unicodedata_name

;; ============================================================================
;; unicodedata.decimal(chr[, default]) -> the digit's value
;;
;; udecimal_value is the derivation str.isdecimal()'s own flag table already
;; supports, and it is exact against the committed table -- all 680 decimal
;; code points agree with CPython.
;; ============================================================================
UDD_DEF   equ 8
UDD_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
DEF_FUNC unicodedata_decimal, UDD_FRAME
    cmp rsi, 1
    jl .udd_arity
    cmp rsi, 2
    jg .udd_arity
    mov qword [rbp - UDD_DEF], 0
    cmp rsi, 2
    jne .udd_no_default
    mov rax, [rdi + 8]
    mov [rbp - UDD_DEF], rax
.udd_no_default:
    mov rdi, [rdi]
    call ud_one_codepoint
    cmp rax, -1
    je .udd_type
    mov edi, eax
    call udecimal_value
    cmp eax, -1
    je .udd_none
    movsxd rdi, eax
    call int_from_i64
    V_PACK rax, rdx
    leave
    ret

.udd_none:
    mov rax, [rbp - UDD_DEF]
    test rax, rax
    jz .udd_not_decimal
    mov rdi, rax
    INCREF_V rdi, rcx
    mov rax, rdi
    leave
    ret

.udd_not_decimal:
    SET_EXC exc_ValueError_type, "not a decimal"
    leave                       ; set_exception answered 0
    ret
.udd_type:
    SET_EXC exc_TypeError_type, "decimal() argument 1 must be a unicode character"
    leave                       ; set_exception answered 0
    ret
.udd_arity:
    SET_EXC exc_TypeError_type, "decimal() takes 1 or 2 arguments"
    leave                       ; set_exception answered 0
    ret
END_FUNC unicodedata_decimal

;; ============================================================================
;; udp_run_lookup(rdi = the table, rsi = its row count, edx = a code point)
;;   -> eax = the row's value
;;
;; A binary search over (dd start, dd value) rows for the LAST row whose start
;; is at or below the code point: the value holds until the next row begins.
;; Row 0 always starts at 0, so the search cannot fall off the front.
;; ============================================================================
DEF_FUNC_BARE udp_run_lookup
    xor r8, r8                  ; lo
    mov r9, rsi                 ; hi, exclusive
.url_loop:
    mov rax, r9
    sub rax, r8
    cmp rax, 1
    jle .url_done
    lea rcx, [r8 + r9]
    shr rcx, 1                  ; mid
    mov eax, [rdi + rcx * 8]
    cmp eax, edx
    ja .url_high
    mov r8, rcx
    jmp .url_loop
.url_high:
    mov r9, rcx
    jmp .url_loop
.url_done:
    mov eax, [rdi + r8 * 8 + 4]
    ret
END_FUNC udp_run_lookup

;; ============================================================================
;; udp_sparse_lookup(rdi = the table, rsi = its row count, edx = a code point,
;;                   ecx = the row's size in 8-byte units)
;;   -> rax = the row's address, or 0 when the code point is not in it
;;
;; The same search over a table that is SPARSE rather than runny -- digit and
;; numeric carry a row per code point that has the property and nothing for
;; the rest -- so a miss is a real miss.
;; ============================================================================
DEF_FUNC_BARE udp_sparse_lookup
    xor r8, r8
    mov r9, rsi
.usl_loop:
    cmp r8, r9
    jae .usl_miss
    lea r10, [r8 + r9]
    shr r10, 1
    mov rax, r10
    imul rax, rcx
    mov eax, [rdi + rax * 8]
    cmp eax, edx
    je .usl_hit
    jb .usl_up
    mov r9, r10
    jmp .usl_loop
.usl_up:
    lea r8, [r10 + 1]
    jmp .usl_loop
.usl_hit:
    mov rax, r10
    imul rax, rcx
    lea rax, [rdi + rax * 8]
    ret
.usl_miss:
    xor eax, eax
    ret
END_FUNC udp_sparse_lookup

;; ============================================================================
;; The three string-valued properties.  Each is the same shape: one code
;; point in, a run lookup, and the pooled string its index names.
;; ============================================================================
%macro UD_STR_PROP 3            ; %1 = python name, %2 = table label, %3 = wording
DEF_FUNC unicodedata_%1
    cmp rsi, 1
    jne .udsp_arity
    mov rdi, [rdi]
    call ud_one_codepoint
    cmp rax, -1
    je .udsp_type
    mov edx, eax
    lea rdi, [rel %2_starts]
    mov rsi, [rel %2_count]
    call udp_run_lookup
    lea rcx, [rel %2_strings]
    mov rdi, [rcx + rax * 8]
    call str_from_cstr_heap
    leave
    ret
.udsp_type:
    SET_EXC exc_TypeError_type, %3
    leave                       ; set_exception answered 0
    ret
.udsp_arity:
    SET_EXC exc_TypeError_type, %3
    leave                       ; set_exception answered 0
    ret
END_FUNC unicodedata_%1
%endmacro

UD_STR_PROP category, udp_category, \
    "category() argument must be a unicode character"
UD_STR_PROP bidirectional, udp_bidi, \
    "bidirectional() argument must be a unicode character"
UD_STR_PROP east_asian_width, udp_eaw, \
    "east_asian_width() argument must be a unicode character"

;; ============================================================================
;; The two integer-valued run properties.
;; ============================================================================
%macro UD_INT_PROP 3            ; %1 = python name, %2 = table label, %3 = wording
DEF_FUNC unicodedata_%1
    cmp rsi, 1
    jne .udip_arity
    mov rdi, [rdi]
    call ud_one_codepoint
    cmp rax, -1
    je .udip_type
    mov edx, eax
    lea rdi, [rel %2_starts]
    mov rsi, [rel %2_count]
    call udp_run_lookup
    movsxd rdi, eax
    call int_from_i64
    V_PACK rax, rdx
    leave
    ret
.udip_type:
    SET_EXC exc_TypeError_type, %3
    leave                       ; set_exception answered 0
    ret
.udip_arity:
    SET_EXC exc_TypeError_type, %3
    leave                       ; set_exception answered 0
    ret
END_FUNC unicodedata_%1
%endmacro

UD_INT_PROP combining, udp_combining, \
    "combining() argument must be a unicode character"
UD_INT_PROP mirrored, udp_mirrored, \
    "mirrored() argument must be a unicode character"

;; ============================================================================
;; unicodedata.digit(chr[, default]) -> the character's digit value
;;
;; Sparse rather than runny: the eight hundred and eight code points that have
;; one, and a real miss for everything else.  Wider than decimal() -- the
;; superscripts and the circled digits are digits and not decimals.
;; ============================================================================
UDG_DEF   equ 8
UDG_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
DEF_FUNC unicodedata_digit, UDG_FRAME
    cmp rsi, 1
    jl .udg_arity
    cmp rsi, 2
    jg .udg_arity
    mov qword [rbp - UDG_DEF], 0
    cmp rsi, 2
    jne .udg_no_default
    mov rax, [rdi + 8]
    mov [rbp - UDG_DEF], rax
.udg_no_default:
    mov rdi, [rdi]
    call ud_one_codepoint
    cmp rax, -1
    je .udg_type
    mov edx, eax
    lea rdi, [rel udp_digit_table]
    mov rsi, [rel udp_digit_count]
    mov ecx, 1                  ; one 8-byte row
    call udp_sparse_lookup
    test rax, rax
    jz .udg_none
    movsxd rdi, dword [rax + 4]
    call int_from_i64
    V_PACK rax, rdx
    leave
    ret
.udg_none:
    mov rax, [rbp - UDG_DEF]
    test rax, rax
    jz .udg_not_digit
    mov rdi, rax
    INCREF_V rdi, rcx
    mov rax, rdi
    leave
    ret
.udg_not_digit:
    SET_EXC exc_ValueError_type, "not a digit"
    leave                       ; set_exception answered 0
    ret
.udg_type:
    SET_EXC exc_TypeError_type, "digit() argument 1 must be a unicode character"
    leave                       ; set_exception answered 0
    ret
.udg_arity:
    SET_EXC exc_TypeError_type, "digit() takes 1 or 2 arguments"
    leave                       ; set_exception answered 0
    ret
END_FUNC unicodedata_digit

;; ============================================================================
;; unicodedata.numeric(chr[, default]) -> the character's numeric value
;;
;; A float, as CPython's is -- but stored as an exact numerator and
;; denominator, because the UCD's values include 1/3 and 1/7 and a generator
;; that wrote the float would be writing a rounding.
;; ============================================================================
UDNM_DEF   equ 8
UDNM_FRAME equ 16           ; + 0 pushes = 16, 16-aligned
DEF_FUNC unicodedata_numeric, UDNM_FRAME
    cmp rsi, 1
    jl .udnm_arity
    cmp rsi, 2
    jg .udnm_arity
    mov qword [rbp - UDNM_DEF], 0
    cmp rsi, 2
    jne .udnm_no_default
    mov rax, [rdi + 8]
    mov [rbp - UDNM_DEF], rax
.udnm_no_default:
    mov rdi, [rdi]
    call ud_one_codepoint
    cmp rax, -1
    je .udnm_type
    mov edx, eax
    lea rdi, [rel udp_numeric_table]
    mov rsi, [rel udp_numeric_count]
    mov ecx, 3                  ; three 8-byte units: cp, numerator, denominator
    call udp_sparse_lookup
    test rax, rax
    jz .udnm_none
    cvtsi2sd xmm0, qword [rax + 8]
    cvtsi2sd xmm1, qword [rax + 16]
    divsd xmm0, xmm1
    call float_from_f64         ; the double is in xmm0, and it answers a PAIR
    V_PACK rax, rdx             ; without which the bits come back as a Value
    leave                       ; 2**48 out -- the shape CLAUDE.md names
    ret
.udnm_none:
    mov rax, [rbp - UDNM_DEF]
    test rax, rax
    jz .udnm_not_numeric
    mov rdi, rax
    INCREF_V rdi, rcx
    mov rax, rdi
    leave
    ret
.udnm_not_numeric:
    SET_EXC exc_ValueError_type, "not a numeric character"
    leave                       ; set_exception answered 0
    ret
.udnm_type:
    SET_EXC exc_TypeError_type, "numeric() argument 1 must be a unicode character"
    leave                       ; set_exception answered 0
    ret
.udnm_arity:
    SET_EXC exc_TypeError_type, "numeric() takes 1 or 2 arguments"
    leave                       ; set_exception answered 0
    ret
END_FUNC unicodedata_numeric

;; ============================================================================
;; unicodedata_module_create() -> the module
;; ============================================================================
UMC_FRAME equ 32            ; + 2 pushes = 48, 16-aligned
DEF_FUNC unicodedata_module_create, UMC_FRAME
    push rbx
    push r12
    call dict_new
    mov r12, rax                ; MODULE_ADD_FUNC reads the dict from r12

    MODULE_ADD_FUNC unicodedata_lookup,  ud_n_lookup
    MODULE_ADD_FUNC unicodedata_name,    ud_n_name
    MODULE_ADD_FUNC unicodedata_decimal, ud_n_decimal
    MODULE_ADD_FUNC unicodedata_digit,   ud_n_digit
    MODULE_ADD_FUNC unicodedata_numeric, ud_n_numeric
    MODULE_ADD_FUNC unicodedata_category, ud_n_category
    MODULE_ADD_FUNC unicodedata_combining, ud_n_combining
    MODULE_ADD_FUNC unicodedata_mirrored, ud_n_mirrored
    MODULE_ADD_FUNC unicodedata_bidirectional, ud_n_bidirectional
    MODULE_ADD_FUNC unicodedata_east_asian_width, ud_n_eaw
    ; The two that need the normalization tables, which are their own file:
    ; src/modules/unicodenorm.asm over src/modules/unicodenorm_tables.asm.
    extern unicodedata_normalize
    MODULE_ADD_FUNC unicodedata_normalize, ud_n_normalize
    extern unicodedata_decomposition
    MODULE_ADD_FUNC unicodedata_decomposition, ud_n_decomposition
    extern unicodedata_is_normalized
    MODULE_ADD_FUNC unicodedata_is_normalized, ud_n_is_normalized

    ; The version the tables were generated from, which is the honest answer:
    ; gen_unicodename.py writes it into its own header from the CPython it
    ; ran under.
    lea rdi, [rel ud_n_version]
    call str_from_cstr_heap
    mov rbx, rax
    lea rdi, [rel ud_v_version]
    call str_from_cstr_heap
    mov rdi, r12
    mov rsi, rbx
    mov rdx, rax
    push rax
    call dict_set
    pop rdi
    call obj_decref
    mov rdi, rbx
    call obj_decref

    ; The frozen 3.2 copy, as an attribute rather than as a module of its own:
    ; `from unicodedata import ucd_3_2_0` is how stringprep reaches it, and
    ; CPython registers it nowhere either.
    extern ucd32_module_create
    call ucd32_module_create
    test rax, rax
    jz .no_ucd32
    mov rbx, rax
    lea rdi, [rel ud_n_ucd32]
    call str_from_cstr_heap
    push rax
    push rax                    ; twice: rsp stays 16-byte aligned
    mov rdi, r12
    mov rsi, rax
    mov rdx, rbx
    call dict_set
    pop rdi
    pop rax
    call obj_decref
    mov rdi, rbx
    call obj_decref
.no_ucd32:

    lea rdi, [rel ud_name]
    call str_from_cstr_heap
    mov rbx, rax
    mov rdi, rax
    mov rsi, r12
    call module_new
    mov rbx, rax
    mov rdi, r12
    call obj_decref
    mov rax, rbx
    pop r12
    pop rbx
    leave
    ret
END_FUNC unicodedata_module_create

section .rodata
ud_name:       db "unicodedata", 0
ud_n_lookup:   db "lookup", 0
ud_n_normalize: db "normalize", 0
ud_n_ucd32:    db "ucd_3_2_0", 0
ud_n_decomposition: db "decomposition", 0
ud_n_is_normalized: db "is_normalized", 0
ud_n_name:     db "name", 0
ud_n_decimal:  db "decimal", 0
ud_n_digit:    db "digit", 0
ud_n_numeric:  db "numeric", 0
ud_n_category: db "category", 0
ud_n_combining: db "combining", 0
ud_n_mirrored: db "mirrored", 0
ud_n_bidirectional: db "bidirectional", 0
ud_n_eaw:      db "east_asian_width", 0
ud_n_version:  db "unidata_version", 0
ud_v_version:  db "15.0.0", 0

ASM_INIT
