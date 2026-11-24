; hashlib.asm - the _hashlibcore module: OpenSSL's EVP and HMAC, and nothing else.
;
; The same split _zlibcore/lib/zlib.py uses, and for the same reasons.  What is
; genuinely C lives here -- the EVP_MD_CTX and HMAC_CTX calls, the handle table
; -- and everything a Python program sees is lib/_hashlib.py: the HASH, HASHXOF
; and HMAC objects, the openssl_<name> constructors, the keyword arguments and
; every default.  So every function here takes a fixed number of positional
; arguments and answers with a bytes, an int, a bool or a tuple.
;
; It is a SHIM, on the precedent -lgmp set at the most load-bearing place there
; is and -lz followed.  What it buys over lib/_sha3.py and lib/_blake2.py is
; not tidiness: it is pbkdf2_hmac and scrypt, which have no honest pure-Python
; form at the iteration counts anyone uses, and three or four orders of
; magnitude on bulk hashing.  CPython's own test_hashlib has two tests that
; hash four gigabytes.
;
; A handle is an INDEX into hc_handles, not a pointer.  A pointer would be an
; integer a Python program could forge and this module would dereference; an
; index is bounds-checked and a freed slot reads back as 0.  One table serves
; both object families, with a `kind` field beside the magic, so the
; bounds-and-magic check is written once.
;
; Unlike ZHandle, the magic sits FIRST here.  zlib had to put its z_stream
; first because it transcribes that struct by hand and libz reads it with
; aligned SSE; EVP_MD_CTX and HMAC_CTX are OPAQUE -- OpenSSL allocates and
; frees its own with its own allocator -- so there is nothing here to align
; and the hazard does not exist.

%include "macros.inc"
%include "object.inc"

ASM_INIT

extern eval_exception_unwind
extern dict_new
extern dict_set
extern module_new
extern str_from_cstr_heap
extern obj_decref
extern int_from_i64
extern builtin_func_new
extern bytes_from_data
extern bytes_type
extern bytearray_type
extern ap_malloc
extern ap_realloc
extern ap_free
extern ap_memset
extern obj_as_index
extern raise_exception
extern exc_TypeError_type
extern exc_ValueError_type
extern exc_MemoryError_type
extern tuple_new
extern bool_true
extern bool_false
extern none_singleton
extern str_type
extern obj_is_true
extern ap_strcmp
extern type_is_subtype

extern EVP_get_digestbyname
extern EVP_MD_CTX_new
extern EVP_MD_CTX_free
extern EVP_MD_CTX_copy_ex
extern EVP_DigestInit_ex
extern EVP_DigestUpdate
extern EVP_DigestFinal_ex
extern EVP_DigestFinalXOF
extern EVP_MD_get_size
extern EVP_MD_get_block_size
extern EVP_MD_get_flags
extern PKCS5_PBKDF2_HMAC
extern EVP_PBE_scrypt
extern HMAC_CTX_new
extern HMAC_CTX_free
extern HMAC_CTX_copy
extern HMAC_Init_ex
extern HMAC_Update
extern HMAC_Final
extern CRYPTO_memcmp

; A handle.  `kind` is what lets one table serve both families.
HC_MAGIC    equ 0x48434D44      ; "HCMD"
HC_EVP      equ 0
HC_HMAC     equ 1

; EVP_MD_FLAG_XOF, from openssl/evp.h.  It is what distinguishes shake from a
; fixed-width digest, and it is asked of the EVP_MD rather than of a name
; table, so a provider that grows a new XOF is handled without a change here.
EVP_MD_FLAG_XOF equ 0x0002

struc HcHandle
    .magic:     resq 1
    .kind:      resq 1
    .ctx:       resq 1          ; EVP_MD_CTX* or HMAC_CTX*, opaque
    .md:        resq 1          ; const EVP_MD*, static inside OpenSSL
    .name:      resq 1          ; a .rodata C string, borrowed
    .xof:       resq 1
    .dsize:     resq 1
    .bsize:     resq 1
endstruc

; The largest digest OpenSSL will hand back through EVP_DigestFinal_ex.
HC_MAX_DIGEST equ 64

; One scrypt cost parameter: read it, refuse a negative, keep it.  Five
; identical blocks would be five chances to use the wrong slot.
%macro HC_SCRYPT_ARG 2          ; %1 = argument index, %2 = the frame slot
    mov rdi, [rbp - SC_ARGS]
    mov esi, %1
    call hc_arg_int
    test rax, rax
    js .failed
    mov [rbp - %2], rax
%endmacro

section .data
align 8
hc_handles:     dq 0            ; HcHandle*[], grown by doubling
hc_handle_cap:  dq 0
hc_handle_n:    dq 0

section .rodata
hc_modname:     db "_hashlibcore", 0

hn_md_names:        db "md_names", 0
hn_new:             db "new", 0
hn_update:          db "update", 0
hn_digest:          db "digest", 0
hn_xof_digest:      db "xof_digest", 0
hn_copy:            db "copy", 0
hn_free:            db "free", 0
hn_info:            db "info", 0
hn_pbkdf2:          db "pbkdf2", 0
hn_scrypt:          db "scrypt", 0
hn_hmac_new:        db "hmac_new", 0
hn_hmac_update:     db "hmac_update", 0
hn_hmac_digest:     db "hmac_digest", 0
hn_hmac_copy:       db "hmac_copy", 0
hn_hmac_free:       db "hmac_free", 0
hn_hmac_info:       db "hmac_info", 0
hn_compare_digest:  db "compare_digest", 0

; The names this module offers, and no more.  CPython's
; openssl_md_meth_names is everything the linked provider has -- about forty
; on an ordinary OpenSSL 3, md4 and whirlpool among them -- and advertising
; those would put names into hashlib.algorithms_available that nothing here
; tests.  These are hashlib's own fourteen, under hashlib's own spellings.
;
; The spellings matter: test_hashlib asserts `"blake2b512" not in
; hashlib.algorithms_available` and `"sha3-512" not in` it either, because
; CPython's _hashopenssl NORMALISES what it reports to the names hashlib uses.
; So the left column is always the PYTHON name, even where OpenSSL's own is
; the only way to ask the provider for that digest.
;
; Each row is a name as PYTHON spells it, then the name to hand
; EVP_get_digestbyname.  They differ for sha3 and shake, and the difference is
; the whole reason for two columns.
align 8
hc_name_table:
    dq hs_md5,       ho_md5
    dq hs_sha1,      ho_sha1
    dq hs_sha224,    ho_sha224
    dq hs_sha256,    ho_sha256
    dq hs_sha384,    ho_sha384
    dq hs_sha512,    ho_sha512
    dq hs_sha3_224,  ho_sha3_224
    dq hs_sha3_256,  ho_sha3_256
    dq hs_sha3_384,  ho_sha3_384
    dq hs_sha3_512,  ho_sha3_512
    dq hs_shake_128, ho_shake_128
    dq hs_shake_256, ho_shake_256
    dq hs_blake2b,   ho_blake2b
    dq hs_blake2s,   ho_blake2s
hc_name_table_end:

hs_md5:       db "md5", 0
hs_sha1:      db "sha1", 0
hs_sha224:    db "sha224", 0
hs_sha256:    db "sha256", 0
hs_sha384:    db "sha384", 0
hs_sha512:    db "sha512", 0
hs_sha3_224:  db "sha3_224", 0
hs_sha3_256:  db "sha3_256", 0
hs_sha3_384:  db "sha3_384", 0
hs_sha3_512:  db "sha3_512", 0
hs_shake_128: db "shake_128", 0
hs_shake_256: db "shake_256", 0
hs_blake2b:   db "blake2b", 0
hs_blake2s:   db "blake2s", 0

ho_md5:       db "MD5", 0
ho_sha1:      db "SHA1", 0
ho_sha224:    db "SHA224", 0
ho_sha256:    db "SHA256", 0
ho_sha384:    db "SHA384", 0
ho_sha512:    db "SHA512", 0
ho_sha3_224:  db "SHA3-224", 0
ho_sha3_256:  db "SHA3-256", 0
ho_sha3_384:  db "SHA3-384", 0
ho_sha3_512:  db "SHA3-512", 0
ho_shake_128: db "SHAKE128", 0
ho_shake_256: db "SHAKE256", 0
ho_blake2b:   db "BLAKE2b512", 0
ho_blake2s:   db "BLAKE2s256", 0

hc_e_nargs:     db "_hashlibcore: wrong number of arguments", 0
hc_e_unknown:   db "unsupported hash type", 0
hc_e_handle:    db "_hashlibcore: stale or invalid handle", 0
hc_e_oom:       db "out of memory", 0
hc_e_init:      db "failed to initialise the digest", 0
hc_e_update:    db "failed to update the digest", 0
hc_e_final:     db "failed to finalise the digest", 0
hc_e_copy:      db "failed to copy the digest", 0
hc_e_bytes:     db "argument must be a bytes-like object", 0
hc_e_pbkdf2:    db "failed to derive the key", 0
hc_e_scrypt:    db "failed to derive the key with scrypt", 0
hc_e_kind:      db "_hashlibcore: handle is of the wrong kind", 0

section .text

;; ============================================================================
;; hc_handle_at(rdi = handle index, rsi = the kind wanted) -> rax = HcHandle*,
;;     or 0 with a ValueError pending
;;
;; Bounds-checked, because the index came from Python, and magic-checked,
;; because a freed slot's memory may have been reused and OpenSSL dereferences
;; whatever it is handed.  The kind check is what keeps one table safe for two
;; families: an HMAC_CTX* passed to EVP_DigestUpdate is a wild write.
;; ============================================================================
HAT_KIND  equ 8
HAT_FRAME equ 16                ; + 0 pushes = 16, 16-aligned
DEF_FUNC_LOCAL hc_handle_at, HAT_FRAME
    mov [rbp - HAT_KIND], rsi
    test rdi, rdi
    js .bad
    cmp rdi, [rel hc_handle_n]
    jae .bad
    mov rax, [rel hc_handles]
    mov rax, [rax + rdi*8]
    test rax, rax
    jz .bad
    cmp qword [rax + HcHandle.magic], HC_MAGIC
    jne .bad
    mov rcx, [rbp - HAT_KIND]
    cmp [rax + HcHandle.kind], rcx
    jne .wrong_kind
    leave
    ret
.wrong_kind:
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rel hc_e_kind]
    call raise_exception
    ud2
.bad:
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rel hc_e_handle]
    call raise_exception
    ud2
END_FUNC hc_handle_at

;; ============================================================================
;; hc_handle_alloc(rdi = a new HcHandle*) -> rax = its index, or -1
;;
;; A freed slot is reused; the table itself only ever grows.  zc_handle_alloc
;; is the same function over the same shape.
;; ============================================================================
HA_H     equ 8
HA_CAP   equ 16
HA_FRAME equ 32                 ; + 1 push = 40 ... padded to 40 below
DEF_FUNC_LOCAL hc_handle_alloc, 40
    push rbx
    mov [rbp - HA_H], rdi
    xor ebx, ebx
.scan:
    cmp rbx, [rel hc_handle_n]
    jae .append
    mov rax, [rel hc_handles]
    cmp qword [rax + rbx*8], 0
    je .take
    inc rbx
    jmp .scan
.take:
    mov rcx, [rbp - HA_H]
    mov [rax + rbx*8], rcx
    mov rax, rbx
    pop rbx
    leave
    ret
.append:
    mov rax, [rel hc_handle_n]
    cmp rax, [rel hc_handle_cap]
    jb .have_room
    mov rax, [rel hc_handle_cap]
    test rax, rax
    jnz .double
    mov eax, 8
    jmp .grow
.double:
    add rax, rax
.grow:
    mov [rbp - HA_CAP], rax
    mov rdi, [rel hc_handles]
    mov rsi, rax
    shl rsi, 3
    call ap_realloc
    test rax, rax
    jz .fail
    mov [rel hc_handles], rax
    mov rcx, [rbp - HA_CAP]
    mov [rel hc_handle_cap], rcx
.have_room:
    mov rax, [rel hc_handle_n]
    mov rcx, [rel hc_handles]
    mov rdx, [rbp - HA_H]
    mov [rcx + rax*8], rdx
    inc qword [rel hc_handle_n]
    pop rbx
    leave
    ret
.fail:
    mov rax, -1
    pop rbx
    leave
    ret
END_FUNC hc_handle_alloc

;; ============================================================================
;; hc_handle_drop(rdi = index) -> nothing; clears the slot so it can be
;;     reused, leaving the table's length alone
;; ============================================================================
DEF_FUNC_BARE hc_handle_drop
    test rdi, rdi
    js .out
    cmp rdi, [rel hc_handle_n]
    jae .out
    mov rax, [rel hc_handles]
    mov qword [rax + rdi*8], 0
.out:
    ret
END_FUNC hc_handle_drop

;; ============================================================================
;; hc_arg_int(rdi = args, rsi = index) -> rax = the int, or raises
;;
;; obj_as_index, not int_to_i64: the latter reads PyIntObject.compact off
;; whatever it is handed, so a str argument had its header read as a number.
;; ============================================================================
DEF_FUNC_BARE hc_arg_int
    mov rdi, [rdi + rsi*8]
    V_UNPACK rdi, rdx
    sub rsp, 8                  ; a call, so the refusal can be seen
    call obj_as_index
    add rsp, 8
    ERR_M1_JUMP
    ret
END_FUNC hc_arg_int

;; ============================================================================
;; hc_buffer(rdi = a Value) -> rax = data pointer, rdx = length; rax = 0 and a
;;     TypeError pending when it is not bytes-like
;;
;; bytes and bytearray only.  A memoryview would need the buffer protocol
;; acquired and released around the call, which no caller here needs.
;; ============================================================================
HB_OBJ   equ 8
HB_FRAME equ 16                 ; + 0 pushes = 16, 16-aligned
DEF_FUNC_LOCAL hc_buffer, HB_FRAME
    mov [rbp - HB_OBJ], rdi
    V_TEST_PTR rdi, rax
    ja .bad
    test rdi, rdi
    jz .bad
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel bytes_type]
    cmp rax, rcx
    je .is_bytes
    lea rcx, [rel bytearray_type]
    cmp rax, rcx
    je .is_bytearray

    ; A SUBCLASS of either is bytes-like too, and refusing one is not a
    ; theoretical gap: `test_hmac` compares two `class mybytes(bytes)`
    ; instances through compare_digest.  The exact-pointer compares above stay
    ; as the fast path -- every ordinary call takes one -- and only a miss pays
    ; for type_is_subtype, which answers off the MRO rather than by following
    ; tp_base (CLAUDE.md: with multiple inheritance tp_base is the wrong
    ; question).  The layout is the base's either way: str and bytes keep their
    ; data inline and a subclass's dict goes at the TAIL for exactly that
    ; reason.
    mov rdi, rax
    lea rsi, [rel bytes_type]
    call type_is_subtype
    test eax, eax
    jnz .sub_bytes
    mov rdi, [rbp - HB_OBJ]
    mov rdi, [rdi + PyObject.ob_type]
    lea rsi, [rel bytearray_type]
    call type_is_subtype
    test eax, eax
    jnz .sub_bytearray
.bad:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel hc_e_bytes]
    call raise_exception
    ud2
.sub_bytes:
    mov rdi, [rbp - HB_OBJ]
.is_bytes:
    mov rdx, [rdi + PyBytesObject.ob_size]
    lea rax, [rdi + PyBytesObject.data]
    leave
    ret
.sub_bytearray:
    mov rdi, [rbp - HB_OBJ]
.is_bytearray:
    mov rdx, [rdi + PyByteArrayObject.ob_size]
    mov rax, [rdi + PyByteArrayObject.ob_bytes]
    leave
    ret
END_FUNC hc_buffer

;; ============================================================================
;; hc_lookup(rdi = a name C string) -> rax = the EVP_MD*, rdx = the table's
;;     Python-side name pointer; rax = 0 when the name is not one of ours
;;
;; The table is consulted first and OpenSSL second, so a name this module does
;; not offer is refused even when the provider has it.  That is the decision
;; recorded in hc_name_table's comment, and it is what keeps
;; hashlib.algorithms_available equal to algorithms_guaranteed plus the two
;; BLAKE2 spellings.
;; ============================================================================
HL_ROW    equ 8
HL_FRAME  equ 16                ; + 2 pushes = 32, 16-aligned
DEF_FUNC_LOCAL hc_lookup, HL_FRAME
    push rbx
    push r12
    mov rbx, rdi                ; the wanted name
    lea r12, [rel hc_name_table]
.row:
    lea rax, [rel hc_name_table_end]
    cmp r12, rax
    jae .miss
    mov rdi, rbx
    mov rsi, [r12]              ; the Python-side spelling
    call ap_strcmp
    test eax, eax
    jz .found
    add r12, 16
    jmp .row
.found:
    mov [rbp - HL_ROW], r12
    mov rdi, [r12 + 8]          ; the OpenSSL spelling
    call EVP_get_digestbyname wrt ..plt
    test rax, rax
    jz .miss
    mov r12, [rbp - HL_ROW]
    mov rdx, [r12]
    pop r12
    pop rbx
    leave
    ret
.miss:
    xor eax, eax
    xor edx, edx
    pop r12
    pop rbx
    leave
    ret
END_FUNC hc_lookup

;; ============================================================================
;; _hashlibcore.md_names() -> tuple[str]
;;
;; The names this module can actually serve: every row of hc_name_table whose
;; OpenSSL spelling the linked provider answers to.  Filtered rather than
;; asserted, because a FIPS build refuses some of them and a program that asks
;; what is available should be told the truth.
;; ============================================================================
MN_TUP    equ 8
MN_N      equ 16
MN_ROW    equ 24
MN_ITEMS  equ 32
MN_FRAME  equ 40                ; + 3 pushes = 64, 16-aligned
DEF_FUNC hc_md_names, MN_FRAME
    push rbx
    push r12
    push r13
    mov r13, rsp
    and rsp, -16                ; libcrypto is reached from here directly
    ; Count first: the tuple is built at its final size rather than grown.
    xor ebx, ebx
    lea r12, [rel hc_name_table]
.count:
    lea rax, [rel hc_name_table_end]
    cmp r12, rax
    jae .have_count
    mov rdi, [r12 + 8]
    call EVP_get_digestbyname wrt ..plt
    test rax, rax
    jz .count_next
    inc rbx
.count_next:
    add r12, 16
    jmp .count
.have_count:
    mov rdi, rbx
    call tuple_new
    test rax, rax
    jz .oom
    mov [rbp - MN_TUP], rax
    mov rax, [rax + PyTupleObject.ob_item]
    mov [rbp - MN_ITEMS], rax
    xor ebx, ebx                ; the write index
    lea r12, [rel hc_name_table]
.fill:
    lea rax, [rel hc_name_table_end]
    cmp r12, rax
    jae .done
    mov [rbp - MN_ROW], r12
    mov rdi, [r12 + 8]
    call EVP_get_digestbyname wrt ..plt
    test rax, rax
    jz .fill_next
    mov r12, [rbp - MN_ROW]
    mov rdi, [r12]
    call str_from_cstr_heap
    test rax, rax
    jz .oom_partial             ; never leave a NULL in a sized tuple
    mov rcx, [rbp - MN_ITEMS]   ; a POINTER to the payload array
    mov [rcx + rbx*8], rax
    inc rbx
.fill_next:
    mov r12, [rbp - MN_ROW]
    add r12, 16
    jmp .fill
.done:
    ; The count and the fill walk the same table under the same filter, so
    ; rbx should equal the counted size -- but publish what was WRITTEN, so a
    ; tuple can never be handed out with a NULL item in its tail.
    mov rcx, [rbp - MN_TUP]
    mov [rcx + PyTupleObject.ob_size], rbx
    mov rax, rcx
    mov rsp, r13
    pop r13
    pop r12
    pop rbx
    leave
    ret
.oom_partial:
    ; Shrink to what was filled, then release it: a sized tuple with a NULL
    ; item is a latent crash for anything that reads it later.
    mov rcx, [rbp - MN_TUP]
    mov [rcx + PyTupleObject.ob_size], rbx
    mov rdi, rcx
    call obj_decref
.oom:
    ; A raise, not an INCREF'd None.  Answering None made
    ; `frozenset(_core.md_names())` a confusing TypeError instead of the
    ; MemoryError it actually was; this entry point is reached from Python
    ; with a live frame, so raise_exception is correct here.
    mov rsp, r13
    pop r13
    pop r12
    pop rbx
    lea rdi, [rel exc_MemoryError_type]
    lea rsi, [rel hc_e_oom]
    call raise_exception
    ud2
END_FUNC hc_md_names

;; ============================================================================
;; _hashlibcore.new(name, usedforsecurity) -> int (a handle)
;;
;; usedforsecurity is taken and ignored, as it is everywhere else here: it
;; selects a FIPS-restricted provider in CPython's build, and this module does
;; not install providers.
;;
;; `and rsp, -16` for the reason zc_stream_feed's docblock records: a builtin
;; is reached from func_call at BOTH parities, OpenSSL is built -O2 and stores
;; to its own frame with aligned SSE, and the symptom would be a general
;; protection fault inside libcrypto rather than a wrong answer.
;; ============================================================================
NW_ARGS   equ 8
NW_H      equ 16
NW_MD     equ 24
NW_NAME   equ 32
NW_SAVE   equ 40
NW_FRAME  equ 48                ; + 1 push = 56 ... padded below
DEF_FUNC hc_new, 56
    push rbx
    mov rbx, rsp
    and rsp, -16
    mov [rbp - NW_ARGS], rdi
    cmp rsi, 2
    jne .nargs

    mov rdi, [rbp - NW_ARGS]
    mov rdi, [rdi]
    V_TEST_PTR rdi, rax
    ja .bad_name
    test rdi, rdi
    jz .bad_name
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    jne .bad_name
    lea rdi, [rdi + PyStrObject.data]
    call hc_lookup
    test rax, rax
    jz .unknown
    mov [rbp - NW_MD], rax
    mov [rbp - NW_NAME], rdx

    mov edi, HcHandle_size
    call ap_malloc
    test rax, rax
    jz .oom
    mov [rbp - NW_H], rax
    mov rdi, rax
    xor esi, esi                ; ap_memset is (dst, VAL, N), in that order
    mov edx, HcHandle_size
    call ap_memset

    call EVP_MD_CTX_new wrt ..plt
    test rax, rax
    jz .oom_ctx
    mov rcx, [rbp - NW_H]
    mov [rcx + HcHandle.ctx], rax

    mov rdi, rax
    mov rsi, [rbp - NW_MD]
    xor edx, edx
    call EVP_DigestInit_ex wrt ..plt
    test eax, eax
    jz .init_failed

    mov rcx, [rbp - NW_H]
    mov qword [rcx + HcHandle.magic], HC_MAGIC
    mov qword [rcx + HcHandle.kind], HC_EVP
    mov rax, [rbp - NW_MD]
    mov [rcx + HcHandle.md], rax
    mov rax, [rbp - NW_NAME]
    mov [rcx + HcHandle.name], rax

    mov rdi, [rbp - NW_MD]
    call EVP_MD_get_size wrt ..plt
    movsx rax, eax
    mov rcx, [rbp - NW_H]
    mov [rcx + HcHandle.dsize], rax
    mov rdi, [rcx + HcHandle.md]
    call EVP_MD_get_block_size wrt ..plt
    movsx rax, eax
    mov rcx, [rbp - NW_H]
    mov [rcx + HcHandle.bsize], rax
    mov rdi, [rcx + HcHandle.md]
    call EVP_MD_get_flags wrt ..plt
    and eax, EVP_MD_FLAG_XOF
    test eax, eax
    setnz al
    movzx eax, al
    mov rcx, [rbp - NW_H]
    mov [rcx + HcHandle.xof], rax

    mov rdi, [rbp - NW_H]
    call hc_handle_alloc
    cmp rax, -1
    je .oom_slot
    mov [rbp - NW_SAVE], rax
    mov rdi, rax
    call int_from_i64           ; a (payload, tag) pair, not a Value yet
    mov rsp, rbx
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.init_failed:
    mov rcx, [rbp - NW_H]
    mov rdi, [rcx + HcHandle.ctx]
    call EVP_MD_CTX_free wrt ..plt
    mov rdi, [rbp - NW_H]
    call ap_free
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rel hc_e_init]
    call raise_exception
    ud2
.oom_slot:
    mov rcx, [rbp - NW_H]
    mov rdi, [rcx + HcHandle.ctx]
    call EVP_MD_CTX_free wrt ..plt
    mov rdi, [rbp - NW_H]
    call ap_free
    jmp .oom_raise
.oom_ctx:
    mov rdi, [rbp - NW_H]
    call ap_free
.oom_raise:
.oom:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rel hc_e_oom]
    call raise_exception
    ud2
.unknown:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rel hc_e_unknown]
    call raise_exception
    ud2
.bad_name:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel hc_e_unknown]
    call raise_exception
    ud2
.nargs:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel hc_e_nargs]
    call raise_exception
    ud2
END_FUNC hc_new

;; ============================================================================
;; _hashlibcore.update(handle, data) -> None
;; ============================================================================
UP_ARGS   equ 8
UP_H      equ 16
UP_FRAME  equ 32                ; + 1 push = 40 ... padded below
DEF_FUNC hc_update, 40
    push rbx
    mov rbx, rsp
    and rsp, -16
    mov [rbp - UP_ARGS], rdi
    cmp rsi, 2
    jne .nargs
    xor esi, esi
    call hc_arg_int
    mov rdi, rax
    mov esi, HC_EVP
    call hc_handle_at
    mov [rbp - UP_H], rax
    mov rdi, [rbp - UP_ARGS]
    mov rdi, [rdi + 8]
    call hc_buffer              ; rax = data, rdx = length
    mov rcx, [rbp - UP_H]
    mov rdi, [rcx + HcHandle.ctx]
    mov rsi, rax
    call EVP_DigestUpdate wrt ..plt
    test eax, eax
    jz .failed
    mov rsp, rbx
    pop rbx
    lea rax, [rel none_singleton]
    INCREF rax
    leave
    ret
.failed:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rel hc_e_update]
    call raise_exception
    ud2
.nargs:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel hc_e_nargs]
    call raise_exception
    ud2
END_FUNC hc_update

;; ============================================================================
;; _hashlibcore.digest(handle) -> bytes
;;
;; Finishes a COPY.  EVP_DigestFinal_ex leaves the context unable to take more
;; data, and a hash object must stay updatable after digest(): `h.digest()`
;; twice answers the same thing, and lib/_sha3.py and lib/_sha2.py do the same
;; for the same reason.
;; ============================================================================
DG_ARGS   equ 8
DG_H      equ 16
DG_TMP    equ 24
DG_LEN    equ 32
DG_BUF    equ 40 + HC_MAX_DIGEST
DG_FRAME  equ ((DG_BUF + 15) / 16) * 16 + 8     ; + 1 push = 16-aligned
DEF_FUNC hc_digest, DG_FRAME
    push rbx
    mov rbx, rsp
    and rsp, -16
    mov [rbp - DG_ARGS], rdi
    cmp rsi, 1
    jne .nargs
    xor esi, esi
    call hc_arg_int
    mov rdi, rax
    mov esi, HC_EVP
    call hc_handle_at
    mov [rbp - DG_H], rax

    call EVP_MD_CTX_new wrt ..plt
    test rax, rax
    jz .oom
    mov [rbp - DG_TMP], rax
    mov rdi, rax
    mov rcx, [rbp - DG_H]
    mov rsi, [rcx + HcHandle.ctx]
    call EVP_MD_CTX_copy_ex wrt ..plt
    test eax, eax
    jz .copy_failed

    mov dword [rbp - DG_LEN], 0
    mov rdi, [rbp - DG_TMP]
    lea rsi, [rbp - DG_BUF]
    lea rdx, [rbp - DG_LEN]
    call EVP_DigestFinal_ex wrt ..plt
    test eax, eax
    jz .final_failed

    mov rdi, [rbp - DG_TMP]
    call EVP_MD_CTX_free wrt ..plt
    lea rdi, [rbp - DG_BUF]
    mov esi, [rbp - DG_LEN]
    call bytes_from_data
    mov rsp, rbx
    pop rbx
    leave
    ret

.final_failed:
    mov rdi, [rbp - DG_TMP]
    call EVP_MD_CTX_free wrt ..plt
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rel hc_e_final]
    call raise_exception
    ud2
.copy_failed:
    mov rdi, [rbp - DG_TMP]
    call EVP_MD_CTX_free wrt ..plt
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rel hc_e_copy]
    call raise_exception
    ud2
.oom:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rel hc_e_oom]
    call raise_exception
    ud2
.nargs:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel hc_e_nargs]
    call raise_exception
    ud2
END_FUNC hc_digest

;; ============================================================================
;; _hashlibcore.xof_digest(handle, length) -> bytes
;;
;; The shake variants.  Same copy-then-finish discipline as hc_digest, but the
;; output length is the caller's and the buffer is allocated rather than on the
;; frame.  lib/_hashlib.py has already validated the length; this refuses a
;; negative one anyway, because a negative reaching ap_malloc is an enormous
;; allocation rather than an error.
;; ============================================================================
XD_ARGS   equ 8
XD_H      equ 16
XD_TMP    equ 24
XD_LEN    equ 32
XD_BUF    equ 40
XD_FRAME  equ 48                ; + 1 push = 56 ... padded below
DEF_FUNC hc_xof_digest, 56
    push rbx
    mov rbx, rsp
    and rsp, -16
    mov [rbp - XD_ARGS], rdi
    cmp rsi, 2
    jne .nargs
    mov qword [rbp - XD_BUF], 0
    mov qword [rbp - XD_TMP], 0
    xor esi, esi
    call hc_arg_int
    mov rdi, rax
    mov esi, HC_EVP
    call hc_handle_at
    mov [rbp - XD_H], rax
    mov rdi, [rbp - XD_ARGS]
    mov esi, 1
    call hc_arg_int
    test rax, rax
    js .bad_length
    mov [rbp - XD_LEN], rax

    ; ap_malloc(0) is not a useful thing to ask for, and a zero-length digest
    ; is legal: bytes_from_data with a length of 0 never reads the pointer.
    test rax, rax
    jz .have_buf
    mov rdi, rax
    call ap_malloc
    test rax, rax
    jz .oom
.have_buf:
    mov [rbp - XD_BUF], rax

    call EVP_MD_CTX_new wrt ..plt
    test rax, rax
    jz .oom
    mov [rbp - XD_TMP], rax
    mov rdi, rax
    mov rcx, [rbp - XD_H]
    mov rsi, [rcx + HcHandle.ctx]
    call EVP_MD_CTX_copy_ex wrt ..plt
    test eax, eax
    jz .failed

    mov rdi, [rbp - XD_TMP]
    mov rsi, [rbp - XD_BUF]
    mov rdx, [rbp - XD_LEN]
    call EVP_DigestFinalXOF wrt ..plt
    test eax, eax
    jz .failed

    mov rdi, [rbp - XD_TMP]
    call EVP_MD_CTX_free wrt ..plt
    mov rdi, [rbp - XD_BUF]
    mov rsi, [rbp - XD_LEN]
    call bytes_from_data
    push rax
    sub rsp, 8
    mov rdi, [rbp - XD_BUF]
    test rdi, rdi
    jz .freed
    call ap_free
.freed:
    add rsp, 8
    pop rax
    mov rsp, rbx
    pop rbx
    leave
    ret

.failed:
    mov rdi, [rbp - XD_TMP]
    test rdi, rdi
    jz .failed_buf
    call EVP_MD_CTX_free wrt ..plt
.failed_buf:
    mov rdi, [rbp - XD_BUF]
    test rdi, rdi
    jz .failed_raise
    call ap_free
.failed_raise:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rel hc_e_final]
    call raise_exception
    ud2
.oom:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rel hc_e_oom]
    call raise_exception
    ud2
.bad_length:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rel hc_e_final]
    call raise_exception
    ud2
.nargs:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel hc_e_nargs]
    call raise_exception
    ud2
END_FUNC hc_xof_digest

;; ============================================================================
;; _hashlibcore.copy(handle) -> int (a new handle)
;; ============================================================================
CP_ARGS   equ 8
CP_SRC    equ 16
CP_H      equ 24
CP_FRAME  equ 32                ; + 1 push = 40 ... padded below
DEF_FUNC hc_copy, 40
    push rbx
    mov rbx, rsp
    and rsp, -16
    mov [rbp - CP_ARGS], rdi
    cmp rsi, 1
    jne .nargs
    xor esi, esi
    call hc_arg_int
    mov rdi, rax
    mov esi, HC_EVP
    call hc_handle_at
    mov [rbp - CP_SRC], rax

    mov edi, HcHandle_size
    call ap_malloc
    test rax, rax
    jz .oom
    mov [rbp - CP_H], rax
    ; Copy every field, then replace the context with a context of its own.
    mov rdi, rax
    mov rsi, [rbp - CP_SRC]
    mov ecx, HcHandle_size / 8
.field:
    mov rax, [rsi]
    mov [rdi], rax
    add rsi, 8
    add rdi, 8
    dec ecx
    jnz .field

    call EVP_MD_CTX_new wrt ..plt
    test rax, rax
    jz .oom_free
    mov rcx, [rbp - CP_H]
    mov [rcx + HcHandle.ctx], rax
    mov rdi, rax
    mov rcx, [rbp - CP_SRC]
    mov rsi, [rcx + HcHandle.ctx]
    call EVP_MD_CTX_copy_ex wrt ..plt
    test eax, eax
    jz .copy_failed

    mov rdi, [rbp - CP_H]
    call hc_handle_alloc
    cmp rax, -1
    je .copy_failed
    mov rdi, rax
    call int_from_i64           ; a (payload, tag) pair, not a Value yet
    mov rsp, rbx
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.copy_failed:
    mov rcx, [rbp - CP_H]
    mov rdi, [rcx + HcHandle.ctx]
    call EVP_MD_CTX_free wrt ..plt
.oom_free:
    mov rdi, [rbp - CP_H]
    call ap_free
.oom:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rel hc_e_copy]
    call raise_exception
    ud2
.nargs:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel hc_e_nargs]
    call raise_exception
    ud2
END_FUNC hc_copy

;; ============================================================================
;; _hashlibcore.free(handle) -> None
;;
;; Freeing a handle twice is not an error: __del__ runs on a path the
;; collector chooses, and lib/_hashlib.py cannot always know whether it has
;; already run.  The magic is zeroed first, so a stale index cannot be revived
;; even if the block is handed straight back out.
;; ============================================================================
FR_ARGS   equ 8
FR_IDX    equ 16
FR_FRAME  equ 32                ; + 1 push = 40 ... padded below
DEF_FUNC hc_free, 40
    push rbx
    mov rbx, rsp
    and rsp, -16
    cmp rsi, 1
    jne .nargs
    xor esi, esi
    call hc_arg_int
    mov [rbp - FR_IDX], rax
    ; Not hc_handle_at: that raises, and this must tolerate a stale index.
    test rax, rax
    js .done
    cmp rax, [rel hc_handle_n]
    jae .done
    mov rcx, [rel hc_handles]
    mov rcx, [rcx + rax*8]
    test rcx, rcx
    jz .done
    cmp qword [rcx + HcHandle.magic], HC_MAGIC
    jne .done
    mov qword [rcx + HcHandle.magic], 0
    push rcx
    sub rsp, 8
    mov rdi, [rcx + HcHandle.ctx]
    test rdi, rdi
    jz .no_ctx
    cmp qword [rcx + HcHandle.kind], HC_HMAC
    je .free_hmac
    call EVP_MD_CTX_free wrt ..plt
    jmp .no_ctx
.free_hmac:
    call HMAC_CTX_free wrt ..plt
.no_ctx:
    add rsp, 8
    pop rdi
    call ap_free
    mov rdi, [rbp - FR_IDX]
    call hc_handle_drop
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
    lea rsi, [rel hc_e_nargs]
    call raise_exception
    ud2
END_FUNC hc_free

;; ============================================================================
;; _hashlibcore.info(handle) -> (name, digest_size, block_size, is_xof)
;;
;; One entry for four attributes, so lib/_hashlib.py reads them once at
;; construction instead of calling across the boundary per attribute access.
;; ============================================================================
IN_ARGS   equ 8
IN_H      equ 16
IN_TUP    equ 24
IN_FRAME  equ 32                ; + 1 push = 40 ... padded below
DEF_FUNC hc_info, 40
    push rbx
    mov rbx, rsp
    and rsp, -16
    mov [rbp - IN_ARGS], rdi
    cmp rsi, 1
    jne .nargs
    xor esi, esi
    call hc_arg_int
    mov rdi, rax
    mov esi, HC_EVP
    call hc_handle_at
    mov [rbp - IN_H], rax
    mov rsp, rbx
    pop rbx
    mov rdi, [rbp - IN_H]
    leave                       ; before the tail jump: hc_info_tuple's own
    jmp hc_info_tuple           ; `leave/ret` would otherwise pop a local
.nargs:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel hc_e_nargs]
    call raise_exception
    ud2
END_FUNC hc_info

;; ============================================================================
;; hc_info_tuple(rdi = HcHandle*) -> the 4-tuple, shared by both families
;; ============================================================================
IT_H     equ 8
IT_TUP   equ 16
IT_FRAME equ 32                 ; + 0 pushes = 32, 16-aligned
DEF_FUNC_LOCAL hc_info_tuple, IT_FRAME
    mov [rbp - IT_H], rdi
    mov edi, 4
    call tuple_new
    test rax, rax
    jz .oom
    mov [rbp - IT_TUP], rax
    mov rcx, [rbp - IT_H]
    mov rdi, [rcx + HcHandle.name]
    call str_from_cstr_heap
    mov rcx, [rbp - IT_TUP]
    mov rcx, [rcx + PyTupleObject.ob_item]  ; a POINTER to the payload array
    mov [rcx], rax
    mov rcx, [rbp - IT_H]
    mov rdi, [rcx + HcHandle.dsize]
    call int_from_i64
    V_PACK rax, rdx             ; a tuple item is a Value
    mov rcx, [rbp - IT_TUP]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov [rcx + 8], rax
    mov rcx, [rbp - IT_H]
    mov rdi, [rcx + HcHandle.bsize]
    call int_from_i64
    V_PACK rax, rdx
    mov rcx, [rbp - IT_TUP]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov [rcx + 16], rax
    mov rcx, [rbp - IT_H]
    cmp qword [rcx + HcHandle.xof], 0
    jne .is_xof
    lea rax, [rel bool_false]
    jmp .store_xof
.is_xof:
    lea rax, [rel bool_true]
.store_xof:
    INCREF rax
    mov rcx, [rbp - IT_TUP]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov [rcx + 24], rax
    mov rax, [rbp - IT_TUP]
    leave
    ret
.oom:
    ; A raise, not an INCREF'd None: the caller unpacks a 4-tuple, and None
    ; there surfaces as a TypeError about iteration rather than as the
    ; MemoryError it is.
    leave
    lea rdi, [rel exc_MemoryError_type]
    lea rsi, [rel hc_e_oom]
    call raise_exception
    ud2
END_FUNC hc_info_tuple

;; ============================================================================
;; _hashlibcore.pbkdf2(name, password, salt, iterations, dklen) -> bytes
;;
;; PKCS5_PBKDF2_HMAC does the whole derivation in C, which is the point: at
;; the iteration counts anyone uses -- 600,000 for a password today -- a
;; Python loop is not a slower option, it is not an option.
;; ============================================================================
PK_ARGS   equ 8
PK_MD     equ 16
PK_PASS   equ 24
PK_PLEN   equ 32
PK_SALT   equ 40
PK_SLEN   equ 48
PK_ITER   equ 56
PK_DKLEN  equ 64
PK_OUT    equ 72
PK_FRAME  equ 80                ; + 1 push = 88 ... padded below
DEF_FUNC hc_pbkdf2, 88
    push rbx
    mov rbx, rsp
    and rsp, -16
    mov [rbp - PK_ARGS], rdi
    cmp rsi, 5
    jne .nargs
    mov qword [rbp - PK_OUT], 0

    mov rdi, [rdi]
    V_TEST_PTR rdi, rax
    ja .bad_name
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    jne .bad_name
    lea rdi, [rdi + PyStrObject.data]
    call hc_lookup
    test rax, rax
    jz .unknown
    mov [rbp - PK_MD], rax

    mov rdi, [rbp - PK_ARGS]
    mov rdi, [rdi + 8]
    call hc_buffer
    mov [rbp - PK_PASS], rax
    mov [rbp - PK_PLEN], rdx
    mov rdi, [rbp - PK_ARGS]
    mov rdi, [rdi + 16]
    call hc_buffer
    mov [rbp - PK_SALT], rax
    mov [rbp - PK_SLEN], rdx

    mov rdi, [rbp - PK_ARGS]
    mov esi, 3
    call hc_arg_int
    test rax, rax
    jle .bad_iter
    mov [rbp - PK_ITER], rax
    mov rdi, [rbp - PK_ARGS]
    mov esi, 4
    call hc_arg_int
    test rax, rax
    jle .bad_dklen
    mov [rbp - PK_DKLEN], rax

    mov rdi, rax
    call ap_malloc
    test rax, rax
    jz .oom
    mov [rbp - PK_OUT], rax

    ; int PKCS5_PBKDF2_HMAC(const char *pass, int passlen,
    ;                       const unsigned char *salt, int saltlen, int iter,
    ;                       const EVP_MD *digest, int keylen,
    ;                       unsigned char *out)
    mov rdi, [rbp - PK_PASS]
    mov esi, [rbp - PK_PLEN]
    mov rdx, [rbp - PK_SALT]
    mov ecx, [rbp - PK_SLEN]
    mov r8d, [rbp - PK_ITER]
    mov r9, [rbp - PK_MD]
    mov eax, [rbp - PK_DKLEN]
    push qword [rbp - PK_OUT]
    push rax
    call PKCS5_PBKDF2_HMAC wrt ..plt
    add rsp, 16
    test eax, eax
    jz .failed

    mov rdi, [rbp - PK_OUT]
    mov rsi, [rbp - PK_DKLEN]
    call bytes_from_data
    push rax
    sub rsp, 8
    mov rdi, [rbp - PK_OUT]
    call ap_free
    add rsp, 8
    pop rax
    mov rsp, rbx
    pop rbx
    leave
    ret

.failed:
    mov rdi, [rbp - PK_OUT]
    call ap_free
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rel hc_e_pbkdf2]
    call raise_exception
    ud2
.oom:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rel hc_e_oom]
    call raise_exception
    ud2
.bad_iter:
.bad_dklen:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rel hc_e_pbkdf2]
    call raise_exception
    ud2
.unknown:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rel hc_e_unknown]
    call raise_exception
    ud2
.bad_name:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel hc_e_unknown]
    call raise_exception
    ud2
.nargs:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel hc_e_nargs]
    call raise_exception
    ud2
END_FUNC hc_pbkdf2

;; ============================================================================
;; _hashlibcore.scrypt(password, salt, n, r, p, maxmem, dklen) -> bytes
;;
;; EVP_PBE_scrypt takes its cost parameters as uint64 and its buffers as
;; size_t, so the seven arguments go in as they arrive.  OpenSSL enforces the
;; n-is-a-power-of-two rule and the maxmem ceiling itself, and answers 0; the
;; wording a caller sees is lib/_hashlib.py's.
;; ============================================================================
SC_ARGS   equ 8
SC_PASS   equ 16
SC_PLEN   equ 24
SC_SALT   equ 32
SC_SLEN   equ 40
SC_N      equ 48
SC_R      equ 56
SC_P      equ 64
SC_MAXMEM equ 72
SC_DKLEN  equ 80
SC_OUT    equ 88
SC_FRAME  equ 96                ; + 1 push = 104 ... padded below
DEF_FUNC hc_scrypt, 104
    push rbx
    mov rbx, rsp
    and rsp, -16
    mov [rbp - SC_ARGS], rdi
    cmp rsi, 7
    jne .nargs
    mov qword [rbp - SC_OUT], 0

    mov rdi, [rdi]
    call hc_buffer
    mov [rbp - SC_PASS], rax
    mov [rbp - SC_PLEN], rdx
    mov rdi, [rbp - SC_ARGS]
    mov rdi, [rdi + 8]
    call hc_buffer
    mov [rbp - SC_SALT], rax
    mov [rbp - SC_SLEN], rdx

    HC_SCRYPT_ARG 2, SC_N
    HC_SCRYPT_ARG 3, SC_R
    HC_SCRYPT_ARG 4, SC_P
    HC_SCRYPT_ARG 5, SC_MAXMEM
    HC_SCRYPT_ARG 6, SC_DKLEN

    mov rax, [rbp - SC_DKLEN]
    test rax, rax
    jle .failed
    mov rdi, rax
    call ap_malloc
    test rax, rax
    jz .oom
    mov [rbp - SC_OUT], rax

    ; int EVP_PBE_scrypt(const char *pass, size_t passlen,
    ;                    const unsigned char *salt, size_t saltlen,
    ;                    uint64_t N, uint64_t r, uint64_t p, uint64_t maxmem,
    ;                    unsigned char *key, size_t keylen)
    mov rdi, [rbp - SC_PASS]
    mov rsi, [rbp - SC_PLEN]
    mov rdx, [rbp - SC_SALT]
    mov rcx, [rbp - SC_SLEN]
    mov r8, [rbp - SC_N]
    mov r9, [rbp - SC_R]
    push qword [rbp - SC_DKLEN]
    push qword [rbp - SC_OUT]
    push qword [rbp - SC_MAXMEM]
    push qword [rbp - SC_P]
    call EVP_PBE_scrypt wrt ..plt
    add rsp, 32
    test eax, eax
    jz .failed

    mov rdi, [rbp - SC_OUT]
    mov rsi, [rbp - SC_DKLEN]
    call bytes_from_data
    push rax
    sub rsp, 8
    mov rdi, [rbp - SC_OUT]
    call ap_free
    add rsp, 8
    pop rax
    mov rsp, rbx
    pop rbx
    leave
    ret

.failed:
    mov rdi, [rbp - SC_OUT]
    test rdi, rdi
    jz .failed_raise
    call ap_free
.failed_raise:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rel hc_e_scrypt]
    call raise_exception
    ud2
.oom:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rel hc_e_oom]
    call raise_exception
    ud2
.nargs:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel hc_e_nargs]
    call raise_exception
    ud2
END_FUNC hc_scrypt

;; ============================================================================
;; _hashlibcore.hmac_new(key, name) -> int (a handle)
;; ============================================================================
HM_ARGS   equ 8
HM_H      equ 16
HM_MD     equ 24
HM_NAME   equ 32
HM_KEY    equ 40
HM_KLEN   equ 48
HM_FRAME  equ 64                ; + 1 push = 72 ... padded below
DEF_FUNC hc_hmac_new, 72
    push rbx
    mov rbx, rsp
    and rsp, -16
    mov [rbp - HM_ARGS], rdi
    cmp rsi, 2
    jne .nargs

    mov rdi, [rdi]
    call hc_buffer
    mov [rbp - HM_KEY], rax
    mov [rbp - HM_KLEN], rdx

    mov rdi, [rbp - HM_ARGS]
    mov rdi, [rdi + 8]
    V_TEST_PTR rdi, rax
    ja .bad_name
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    jne .bad_name
    lea rdi, [rdi + PyStrObject.data]
    call hc_lookup
    test rax, rax
    jz .unknown
    mov [rbp - HM_MD], rax
    mov [rbp - HM_NAME], rdx

    mov edi, HcHandle_size
    call ap_malloc
    test rax, rax
    jz .oom
    mov [rbp - HM_H], rax
    mov rdi, rax
    xor esi, esi                ; ap_memset is (dst, VAL, N), in that order
    mov edx, HcHandle_size
    call ap_memset

    call HMAC_CTX_new wrt ..plt
    test rax, rax
    jz .oom_free
    mov rcx, [rbp - HM_H]
    mov [rcx + HcHandle.ctx], rax

    ; HMAC_Init_ex(ctx, key, key_len, md, impl) -- a zero-length key is legal
    ; and is NOT the same as a NULL key, which means "reuse the last one".
    mov rdi, rax
    mov rsi, [rbp - HM_KEY]
    mov edx, [rbp - HM_KLEN]
    mov rcx, [rbp - HM_MD]
    xor r8d, r8d
    call HMAC_Init_ex wrt ..plt
    test eax, eax
    jz .init_failed

    mov rcx, [rbp - HM_H]
    mov qword [rcx + HcHandle.magic], HC_MAGIC
    mov qword [rcx + HcHandle.kind], HC_HMAC
    mov rax, [rbp - HM_MD]
    mov [rcx + HcHandle.md], rax
    mov rax, [rbp - HM_NAME]
    mov [rcx + HcHandle.name], rax
    mov rdi, [rbp - HM_MD]
    call EVP_MD_get_size wrt ..plt
    movsx rax, eax
    mov rcx, [rbp - HM_H]
    mov [rcx + HcHandle.dsize], rax
    mov rdi, [rcx + HcHandle.md]
    call EVP_MD_get_block_size wrt ..plt
    movsx rax, eax
    mov rcx, [rbp - HM_H]
    mov [rcx + HcHandle.bsize], rax

    mov rdi, rcx
    call hc_handle_alloc
    cmp rax, -1
    je .init_failed
    mov rdi, rax
    call int_from_i64           ; a (payload, tag) pair, not a Value yet
    mov rsp, rbx
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.init_failed:
    mov rcx, [rbp - HM_H]
    mov rdi, [rcx + HcHandle.ctx]
    call HMAC_CTX_free wrt ..plt
.oom_free:
    mov rdi, [rbp - HM_H]
    call ap_free
.oom:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rel hc_e_init]
    call raise_exception
    ud2
.unknown:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rel hc_e_unknown]
    call raise_exception
    ud2
.bad_name:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel hc_e_unknown]
    call raise_exception
    ud2
.nargs:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel hc_e_nargs]
    call raise_exception
    ud2
END_FUNC hc_hmac_new

;; ============================================================================
;; _hashlibcore.hmac_update(handle, data) -> None
;; ============================================================================
HU_ARGS   equ 8
HU_H      equ 16
HU_FRAME  equ 32                ; + 1 push = 40 ... padded below
DEF_FUNC hc_hmac_update, 40
    push rbx
    mov rbx, rsp
    and rsp, -16
    mov [rbp - HU_ARGS], rdi
    cmp rsi, 2
    jne .nargs
    xor esi, esi
    call hc_arg_int
    mov rdi, rax
    mov esi, HC_HMAC
    call hc_handle_at
    mov [rbp - HU_H], rax
    mov rdi, [rbp - HU_ARGS]
    mov rdi, [rdi + 8]
    call hc_buffer
    mov rcx, [rbp - HU_H]
    mov rdi, [rcx + HcHandle.ctx]
    mov rsi, rax
    call HMAC_Update wrt ..plt
    test eax, eax
    jz .failed
    mov rsp, rbx
    pop rbx
    lea rax, [rel none_singleton]
    INCREF rax
    leave
    ret
.failed:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rel hc_e_update]
    call raise_exception
    ud2
.nargs:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel hc_e_nargs]
    call raise_exception
    ud2
END_FUNC hc_hmac_update

;; ============================================================================
;; _hashlibcore.hmac_digest(handle) -> bytes
;;
;; Through a COPY, for the same reason hc_digest is: HMAC_Final finishes the
;; context, and an hmac object stays updatable after .digest().
;; ============================================================================
HD_ARGS   equ 8
HD_H      equ 16
HD_TMP    equ 24
HD_LEN    equ 32
HD_BUF    equ 40 + HC_MAX_DIGEST
HD_FRAME  equ ((HD_BUF + 15) / 16) * 16 + 8     ; + 1 push = 16-aligned
DEF_FUNC hc_hmac_digest, HD_FRAME
    push rbx
    mov rbx, rsp
    and rsp, -16
    mov [rbp - HD_ARGS], rdi
    cmp rsi, 1
    jne .nargs
    xor esi, esi
    call hc_arg_int
    mov rdi, rax
    mov esi, HC_HMAC
    call hc_handle_at
    mov [rbp - HD_H], rax

    call HMAC_CTX_new wrt ..plt
    test rax, rax
    jz .oom
    mov [rbp - HD_TMP], rax
    mov rdi, rax
    mov rcx, [rbp - HD_H]
    mov rsi, [rcx + HcHandle.ctx]
    call HMAC_CTX_copy wrt ..plt
    test eax, eax
    jz .failed

    mov dword [rbp - HD_LEN], 0
    mov rdi, [rbp - HD_TMP]
    lea rsi, [rbp - HD_BUF]
    lea rdx, [rbp - HD_LEN]
    call HMAC_Final wrt ..plt
    test eax, eax
    jz .failed

    mov rdi, [rbp - HD_TMP]
    call HMAC_CTX_free wrt ..plt
    lea rdi, [rbp - HD_BUF]
    mov esi, [rbp - HD_LEN]
    call bytes_from_data
    mov rsp, rbx
    pop rbx
    leave
    ret
.failed:
    mov rdi, [rbp - HD_TMP]
    call HMAC_CTX_free wrt ..plt
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rel hc_e_final]
    call raise_exception
    ud2
.oom:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rel hc_e_oom]
    call raise_exception
    ud2
.nargs:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel hc_e_nargs]
    call raise_exception
    ud2
END_FUNC hc_hmac_digest

;; ============================================================================
;; _hashlibcore.hmac_copy(handle) -> int (a new handle)
;; ============================================================================
HP_ARGS   equ 8
HP_SRC    equ 16
HP_H      equ 24
HP_FRAME  equ 32                ; + 1 push = 40 ... padded below
DEF_FUNC hc_hmac_copy, 40
    push rbx
    mov rbx, rsp
    and rsp, -16
    mov [rbp - HP_ARGS], rdi
    cmp rsi, 1
    jne .nargs
    xor esi, esi
    call hc_arg_int
    mov rdi, rax
    mov esi, HC_HMAC
    call hc_handle_at
    mov [rbp - HP_SRC], rax

    mov edi, HcHandle_size
    call ap_malloc
    test rax, rax
    jz .oom
    mov [rbp - HP_H], rax
    mov rdi, rax
    mov rsi, [rbp - HP_SRC]
    mov ecx, HcHandle_size / 8
.field:
    mov rax, [rsi]
    mov [rdi], rax
    add rsi, 8
    add rdi, 8
    dec ecx
    jnz .field

    call HMAC_CTX_new wrt ..plt
    test rax, rax
    jz .oom_free
    mov rcx, [rbp - HP_H]
    mov [rcx + HcHandle.ctx], rax
    mov rdi, rax
    mov rcx, [rbp - HP_SRC]
    mov rsi, [rcx + HcHandle.ctx]
    call HMAC_CTX_copy wrt ..plt
    test eax, eax
    jz .copy_failed

    mov rdi, [rbp - HP_H]
    call hc_handle_alloc
    cmp rax, -1
    je .copy_failed
    mov rdi, rax
    call int_from_i64           ; a (payload, tag) pair, not a Value yet
    mov rsp, rbx
    pop rbx
    leave
    V_PACK rax, rdx
    ret
.copy_failed:
    mov rcx, [rbp - HP_H]
    mov rdi, [rcx + HcHandle.ctx]
    call HMAC_CTX_free wrt ..plt
.oom_free:
    mov rdi, [rbp - HP_H]
    call ap_free
.oom:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rel hc_e_copy]
    call raise_exception
    ud2
.nargs:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel hc_e_nargs]
    call raise_exception
    ud2
END_FUNC hc_hmac_copy

;; ============================================================================
;; _hashlibcore.hmac_info(handle) -> (name, digest_size, block_size, is_xof)
;; ============================================================================
HI_ARGS   equ 8
HI_H      equ 16
HI_FRAME  equ 32                ; + 1 push = 40 ... padded below
DEF_FUNC hc_hmac_info, 40
    push rbx
    mov rbx, rsp
    and rsp, -16
    cmp rsi, 1
    jne .nargs
    xor esi, esi
    call hc_arg_int
    mov rdi, rax
    mov esi, HC_HMAC
    call hc_handle_at
    mov [rbp - HI_H], rax
    mov rsp, rbx
    pop rbx
    mov rdi, [rbp - HI_H]
    leave                       ; before the tail jump: hc_info_tuple's own
    jmp hc_info_tuple           ; `leave/ret` would otherwise pop a local
.nargs:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel hc_e_nargs]
    call raise_exception
    ud2
END_FUNC hc_hmac_info

;; ============================================================================
;; _hashlibcore.hmac_free(handle) -> None -- hc_free handles both kinds
;; ============================================================================
DEF_FUNC hc_hmac_free
    leave
    jmp hc_free
END_FUNC hc_hmac_free

;; ============================================================================
;; _hashlibcore.compare_digest(a, b) -> bool
;;
;; CRYPTO_memcmp, not ap_memcmp: it is written to take the same time whatever
;; the inputs are, which is the entire reason this function exists rather than
;; `a == b` being used.  Unequal lengths answer False without comparing, which
;; is what CPython's does too -- the length is not a secret.
;; ============================================================================
CD_ARGS   equ 8
CD_A      equ 16
CD_ALEN   equ 24
CD_FRAME  equ 32                ; + 1 push = 40 ... padded below
DEF_FUNC hc_compare_digest, 40
    push rbx
    mov rbx, rsp
    and rsp, -16
    mov [rbp - CD_ARGS], rdi
    cmp rsi, 2
    jne .nargs
    mov rdi, [rdi]
    call hc_buffer
    mov [rbp - CD_A], rax
    mov [rbp - CD_ALEN], rdx
    mov rdi, [rbp - CD_ARGS]
    mov rdi, [rdi + 8]
    call hc_buffer              ; rax = b, rdx = blen
    cmp rdx, [rbp - CD_ALEN]
    jne .not_equal
    mov rdi, [rbp - CD_A]
    mov rsi, rax
    call CRYPTO_memcmp wrt ..plt
    test eax, eax
    jnz .not_equal
    mov rsp, rbx
    pop rbx
    lea rax, [rel bool_true]
    INCREF rax
    leave
    ret
.not_equal:
    mov rsp, rbx
    pop rbx
    lea rax, [rel bool_false]
    INCREF rax
    leave
    ret
.nargs:
    mov rsp, rbx
    pop rbx
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel hc_e_nargs]
    call raise_exception
    ud2
END_FUNC hc_compare_digest

;; ============================================================================
;; hashlib_module_create() -> the _hashlibcore module object
;; ============================================================================
HM2_FRAME equ 16                ; + 3 pushes = 40 ... padded below
DEF_FUNC hashlib_module_create, 24
    push rbx
    push r12
    push r13

    call dict_new
    mov r12, rax                ; MODULE_ADD_FUNC reads the dict from r12

    MODULE_ADD_FUNC hc_md_names,       hn_md_names
    MODULE_ADD_FUNC hc_new,            hn_new
    MODULE_ADD_FUNC hc_update,         hn_update
    MODULE_ADD_FUNC hc_digest,         hn_digest
    MODULE_ADD_FUNC hc_xof_digest,     hn_xof_digest
    MODULE_ADD_FUNC hc_copy,           hn_copy
    MODULE_ADD_FUNC hc_free,           hn_free
    MODULE_ADD_FUNC hc_info,           hn_info
    MODULE_ADD_FUNC hc_pbkdf2,         hn_pbkdf2
    MODULE_ADD_FUNC hc_scrypt,         hn_scrypt
    MODULE_ADD_FUNC hc_hmac_new,       hn_hmac_new
    MODULE_ADD_FUNC hc_hmac_update,    hn_hmac_update
    MODULE_ADD_FUNC hc_hmac_digest,    hn_hmac_digest
    MODULE_ADD_FUNC hc_hmac_copy,      hn_hmac_copy
    MODULE_ADD_FUNC hc_hmac_free,      hn_hmac_free
    MODULE_ADD_FUNC hc_hmac_info,      hn_hmac_info
    MODULE_ADD_FUNC hc_compare_digest, hn_compare_digest

    lea rdi, [rel hc_modname]
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
END_FUNC hashlib_module_create
