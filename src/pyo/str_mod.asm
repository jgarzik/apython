; pyo/str_mod.asm - the `%` operator, for str and for bytes
;
; Split out of pyo/str.asm, which was over the 100k cap that src/compiler/
; lint.py holds hand-written files to.  This is the seam the file already had:
; the format-directive scanner and everything it reaches is one unit, entered
; only through the nb_remainder slot and through bytes_mod, and it shares
; nothing with the rest of str.asm but the type object.

%include "macros.inc"
%include "object.inc"

extern ap_malloc
extern ap_free
extern bool_true
extern int_to_i64
extern int_unwrap
extern int_is_integer
extern raise_exception
extern exc_TypeError_type
extern exc_OverflowError_type
extern str_type

extern obj_dealloc
extern str_new_heap
section .rodata
; The conversion characters `%` accepts, in CPython's order.  %b is bytes'
; alone; everything else is common to both.
sm_convs:       db "diouxXeEfFgGcrsa%", 0
sm_convs_bytes: db "diouxXeEfFgGcrsab%", 0

section .bss
; The "unsupported format character" message, built in place.
sm_convbuf: resb 128

section .text
;; ============================================================================
;; str_mod(PyStrObject *fmt, PyObject *args) -> PyStrObject*
;; nb_remainder: implements "fmt % args" string formatting
;; Handles: %s, %d, %i, %r, %f, %%
;; args can be a single value or a tuple
;; ============================================================================
extern obj_str
extern int_type
extern exc_ValueError_type
extern obj_repr
extern tuple_type
extern dict_type
extern obj_decref

; str_mod stack offsets
SM_FMT     equ 8
SM_ARGS    equ 16
SM_BUF     equ 24
SM_CAP     equ 32
SM_ISTUPLE equ 40
SM_NARGS   equ 48
SM_ATAG    equ 56
SM_KEYVAL  equ 64        ; value picked out by a %(name)s mapping key, or 0
SM_HASKEY  equ 72
SM_SPECST  equ 80        ; start of the flags/width/precision text
SM_POS     equ 88        ; input position, across calls
SM_SPEC    equ 128       ; 40 bytes of translated format spec, [rbp-128, rbp-88)
SM_CONV    equ 136
SM_SPECOBJ equ 144
SM_VALUE   equ 152
SM_PIECE   equ 160
SM_OWNVAL  equ 168
SM_ISMAP   equ 176       ; the right operand is a mapping: %(name)s, no arity check
SM_SPECCH  equ 184       ; the conversion as format() spells it: i and u are d
SM_ISBYTES equ 192       ; formatting a BYTES: %s means bytes, %r means b'x'
; Report a failure by RETURNING 0 with the exception set, rather than by
; raising.  bytes_mod asks for this: it holds a decoded copy of the format and
; a raise abandons the C stack, so the copy was leaked once per malformed
; `b"%d" % (1, 2)`.  The nb_remainder slot cannot use it -- a NULL from a
; number slot means "declined", and the interpreter would then look for a
; dunder instead of reporting the error.
SM_NORAISE equ 248
SM_KEYOBJ  equ 200       ; the %(name)s key, for the message when it is missing
SM_STARW   equ 208       ; a '*' width taken from the argument list
SM_STARWON equ 216       ; ...and whether there was one
SM_STARP   equ 224       ; a '*' precision, likewise
SM_STARPON equ 232
SM_SAWDOT  equ 240       ; the spec copier's cursor has passed the '.'
SM_SAVERSP equ 264       ; .sm_ensure_cap's saved rsp; see the note there
SM_FRAME   equ 272          ; + 0 pushes = 272; the five pushes below are
                            ; mid-body, which is why lint cannot see them

;; str_mod(rdi = the format, a Value; rsi = the argument, a Value)
;;   -> (rax = the formatted str, rdx = TAG_PTR), or does not return
;;
;; str_mod is the nb_remainder slot.  str_mod_impl is what bytes_mod calls, with
;; the flag that changes what half the conversions mean: %s on a bytes REQUIRES
;; a bytes-like where str's takes anything, %r has to answer b'x' and not 'x',
;; %b exists at all, and %c takes a byte.  bytes % used to reach here by
;; latin-1 decoding the format and every bytes-like argument up front, which
;; cannot express any of that -- the conversion is only known here, so the
;; argument is converted here.
DEF_FUNC_BARE str_mod
    xor ecx, ecx                ; the slot raises; only bytes_mod does not
    xor edx, edx
    jmp str_mod_impl
END_FUNC str_mod

;; ============================================================================
;; str_mod_impl(rdi = the format, a Value; rsi = the argument, a Value;
;;              rcx = 1 to report by returning 0, rdx = 1 for a bytes format)
;;   -> (rax = the formatted object, rdx = TAG_PTR), or (0, 0) with the
;;      exception set when rcx said so
;; ============================================================================
global str_mod_impl
DEF_FUNC str_mod_impl, SM_FRAME
    mov [rbp-SM_ISBYTES], rdx
    mov [rbp-SM_NORAISE], rcx
    BINOP_REQUIRE_LEFT str_type, TYPE_FLAG_STR_SUBCLASS, 1
    V_UNPACK rdi, rdx           ; left  Value -> (payload, tag)
    V_UNPACK rsi, rcx           ; right Value -> (payload, tag)
    ; Stack layout:
    ; [rbp-SM_FMT]     = fmt string
    ; [rbp-SM_ARGS]    = args (single value or tuple)
    ; [rbp-SM_BUF]     = heap buffer ptr
    ; [rbp-SM_CAP]     = buffer capacity
    ; [rbp-SM_ISTUPLE] = is_tuple (bool)
    ; [rbp-SM_NARGS]   = nargs (int)
    ; r13 = buffer ptr, r14 = output pos, r15 = arg index

    push rbx
    push r12
    push r13
    push r14
    push r15

    mov [rbp-SM_FMT], rdi      ; fmt
    mov [rbp-SM_ARGS], rsi     ; args
    mov [rbp-SM_ATAG], rcx     ; args tag

    ; Determine if args is a tuple
    ; rcx = right_tag (args tag) from op_binary_op caller
    mov qword [rbp-SM_ISTUPLE], 0  ; is_tuple = false
    mov qword [rbp-SM_ISMAP], 0
    mov qword [rbp-SM_NARGS], 1   ; nargs = 1 (single value)
    cmp ecx, TAG_PTR
    jne .sm_not_tuple           ; non-heap → single value (SmallInt/Float/Bool/None)
    ; A mapping is addressed by key, so it has no argument count to check.
    ; CPython's test is PyMapping_Check -- anything with an mp_subscript --
    ; and not just a dict, which is why `"ab" % [1, 2]` is 'ab' there and was
    ; a TypeError here.  A tuple is excluded below (it is the argument list),
    ; and a str is excluded here (it is a single value).
    push rsi
    mov rax, [rsi + PyObject.ob_type]
    REQUIRE_STR_TYPE rax, rcx, .sm_map_check
    jmp .sm_not_map
.sm_map_check:
    ; A tuple has an mp_subscript too, and it is the argument list rather than
    ; a mapping -- treating one as a mapping skipped the arity check, so
    ; `"%s" % ("a", "b")` quietly formatted the first and dropped the second.
    mov rax, [rsi + PyObject.ob_type]
    REQUIRE_TUPLE_TYPE rax, rcx, .sm_map_not_tuple
    jmp .sm_not_map
.sm_map_not_tuple:
    ; In a BYTES format a bytes or bytearray argument is a single value, not a
    ; mapping, exactly as a str is for a str format.  Both have an
    ; mp_subscript, so without this b"ab" % b"cd" skipped the arity check and
    ; answered b'ab' instead of saying the argument was never converted.
    cmp qword [rbp-SM_ISBYTES], 0
    je .sm_map_not_bytes
    mov rdi, rsi
    extern bytes_mod_is_byteslike
    call bytes_mod_is_byteslike
    test eax, eax
    jnz .sm_not_map
.sm_map_not_bytes:
    mov rax, [rsi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_mapping]
    test rax, rax
    jz .sm_not_map
    cmp qword [rax + PyMappingMethods.mp_subscript], 0
    je .sm_not_map
    mov qword [rbp-SM_ISMAP], 1
.sm_not_map:
    pop rsi
    mov rcx, [rbp-SM_ATAG]
    ; A tuple SUBCLASS is a tuple here.  The exact-type test this replaces took
    ; one for a single value, so `'(x=%r, y=%r)' % self` -- which is what
    ; collections.namedtuple's __repr__ is -- read one argument for two
    ; conversions and walked off the end of the list.
    mov rax, [rsi + PyObject.ob_type]
    REQUIRE_TUPLE_TYPE rax, rcx, .sm_not_tuple
    mov qword [rbp-SM_ISTUPLE], 1  ; is_tuple = true
    mov rax, [rsi + PyTupleObject.ob_size]
    mov [rbp-SM_NARGS], rax    ; nargs = tuple size
.sm_not_tuple:

    ; The output buffer, which .sm_ensure_cap doubles as needed.
    ;
    ; It used to start at 8192 bytes -- for EVERY `%` operation, including
    ; `"%s-%d" % ("abc", i)`, whose answer is eight bytes.  That is over the
    ; pool allocator's small-object threshold, so it was also a libc round
    ; trip every time; 256 is a size class, and it still holds every format
    ; result short of a deliberately long one in a single allocation.
    extern ap_malloc, ap_free, ap_realloc
    mov edi, 256
    call ap_malloc
    mov r13, rax               ; r13 = output buffer
    mov [rbp-SM_BUF], rax
    mov qword [rbp-SM_CAP], 256
    xor r14d, r14d             ; r14 = output pos
    xor r15d, r15d             ; r15 = arg index
    mov qword [rbp-SM_HASKEY], 0

    ; Walk format string
    mov rbx, [rbp-SM_FMT]     ; fmt string
    mov r12, [rbx + PyStrObject.ob_size]  ; fmt length
    lea rbx, [rbx + PyStrObject.data]     ; fmt data
    xor ecx, ecx               ; input pos

.sm_loop:
    cmp rcx, r12
    jge .sm_done

    movzx eax, byte [rbx + rcx]
    cmp al, '%'
    je .sm_format
    ; Regular char: ensure 1 byte of space
    push rcx
    lea rdi, [r14 + 1]
    call .sm_ensure_cap
    pop rcx
    ; Copy char to output
    movzx eax, byte [rbx + rcx]
    mov [r13 + r14], al
    inc r14
    inc rcx
    jmp .sm_loop

.sm_format:
    ; '%' found — skip optional format spec, then dispatch on conversion char
    ; Format: %[flags][width][.precision]conversion
    ; Flags: -, +, 0, #, space
    ; Width: digits
    ; Precision: . followed by digits
    inc rcx
    cmp rcx, r12
    jge .sm_done

    ; `%%` is a literal percent, and CPython recognises it HERE -- before any
    ; flag, width or precision has been read.  A '%' that turns up as the
    ; conversion letter AFTER them, as in "%.2%", is neither a literal nor a
    ; conversion: CPython calls it an unsupported format character, and this
    ; echoed a percent sign and carried on.
    cmp byte [rbx + rcx], '%'
    jne .sm_not_literal_pct
    push rcx
    lea rdi, [r14 + 1]
    call .sm_ensure_cap
    pop rcx
    mov byte [r13 + r14], '%'
    inc r14
    inc rcx
    jmp .sm_loop
.sm_not_literal_pct:

    ; %(name)s -- a mapping key.  This was never parsed, so the whole
    ; directive was copied through and "%(a)s" % {"a": 1} returned itself.
    mov qword [rbp-SM_HASKEY], 0
    cmp byte [rbx + rcx], '('
    jne .sm_mark_spec
    inc rcx
    mov r8, rcx                     ; start of the key
.sm_key_scan:
    cmp rcx, r12
    jge .sm_key_unterminated
    cmp byte [rbx + rcx], ')'
    je .sm_key_end
    inc rcx
    jmp .sm_key_scan
.sm_key_end:
    ; Build the key string and look it up in the mapping.
    push rcx
    push r8
    lea rdi, [rbx + r8]
    mov rsi, rcx
    sub rsi, r8
    call str_new_heap
    pop r8
    pop rcx
    ; A BYTES format is keyed by BYTES.  The format was decoded to a str to be
    ; scanned, so the key comes out of that str and has to go back -- without
    ; which b"%(a)s" % {b"a": b"x"} looked up "a" in a dict that has b"a".
    cmp qword [rbp-SM_ISBYTES], 0
    je .sm_key_have
    push rcx
    push rax
    mov rdi, rax
    extern bytes_latin1_from_str
    call bytes_latin1_from_str
    pop rdi
    push rax
    call obj_decref                 ; the str key
    pop rax
    pop rcx
.sm_key_have:
    push rcx
    push rax
    mov [rbp-SM_KEYOBJ], rax        ; the key, ours to release
    mov rdi, [rbp-SM_ARGS]
    mov rsi, rax
    call str_mod_subscript
    mov r9, rax
    pop rdi
    pop rcx
    ; Release the key only once the lookup has answered: the error path names
    ; it in the exception, and freeing it first left that reading freed memory.
    test r9, r9
    jz .sm_key_error
    push rcx
    push r9
    call obj_decref
    pop r9
    pop rcx
    mov [rbp-SM_KEYVAL], r9
    mov qword [rbp-SM_HASKEY], 1
    inc rcx                         ; step past ')'

.sm_mark_spec:
    mov qword [rbp-SM_STARWON], 0
    mov qword [rbp-SM_STARPON], 0
    ; Remember where the flags start.  This used to sit on .sm_skip_flags
    ; itself, which .sm_skip_one jumps back to once per flag -- so the marker
    ; ended up *after* the flags and "%-5s" looked like it had none.
    mov [rbp-SM_SPECST], rcx

.sm_skip_flags:
    movzx eax, byte [rbx + rcx]
    cmp al, '-'
    je .sm_skip_one
    cmp al, '+'
    je .sm_skip_one
    cmp al, '0'
    je .sm_skip_one
    cmp al, '#'
    je .sm_skip_one
    cmp al, ' '
    je .sm_skip_one
    jmp .sm_skip_width
.sm_skip_one:
    inc rcx
    cmp rcx, r12
    jge .sm_done
    jmp .sm_skip_flags

.sm_skip_width:
    movzx eax, byte [rbx + rcx]
    cmp al, '*'
    je .sm_star_width
    cmp al, '0'
    jb .sm_check_dot
    cmp al, '9'
    ja .sm_check_dot
    inc rcx
    cmp rcx, r12
    jge .sm_done
    jmp .sm_skip_width

.sm_check_dot:
    cmp al, '.'
    jne .sm_dispatch
    inc rcx                    ; skip '.'
    cmp rcx, r12
    jge .sm_done
.sm_skip_prec:
    movzx eax, byte [rbx + rcx]
    cmp al, '*'
    je .sm_star_prec
    cmp al, '0'
    jb .sm_dispatch
    cmp al, '9'
    ja .sm_dispatch
    inc rcx
    cmp rcx, r12
    jge .sm_done
    jmp .sm_skip_prec

;; "%*d" % (6, 42) and "%.*g" % (3, x): the width, the precision or both come
;; from the argument list.  The whole family was unhandled -- '*' is not a
;; flag, not a digit and not '.', so the scanner stopped there, the conversion
;; went out with no width, and the width argument was still sitting in the
;; tuple when the arity check ran.  What that reported was "not all arguments
;; converted during string formatting", which names neither the directive nor
;; the reason.
.sm_star_width:
    push rcx
    call .sm_get_arg            ; rax = payload, rdx = tag
    call .sm_star_to_i64
    pop rcx
    mov [rbp-SM_STARW], rax
    mov qword [rbp-SM_STARWON], 1
    inc rcx
    cmp rcx, r12
    jge .sm_done
    movzx eax, byte [rbx + rcx] ; .sm_check_dot reads the character in al
    jmp .sm_check_dot

.sm_star_prec:
    push rcx
    call .sm_get_arg
    call .sm_star_to_i64
    pop rcx
    ; A negative precision is no precision at all -- CPython's
    ; "%.*g" % (-1, 1.5) is "%.0g" % 1.5, which is '2'.
    test rax, rax
    jns .sm_star_prec_pos
    xor eax, eax
    jmp .sm_star_prec_keep
.sm_star_prec_pos:
    ; CPython's precision is a C int, and a '*' one is converted straight to
    ; one -- so an int too big for it is an OverflowError here, and not the
    ; ValueError the spec parser would give the same number written out.
    cmp rax, 0x7FFFFFFF     ; rcx is the scan position here, so no scratch
    ja .sm_prec_overflow
.sm_star_prec_keep:
    mov [rbp-SM_STARP], rax
    mov qword [rbp-SM_STARPON], 1
    inc rcx
    cmp rcx, r12
    jge .sm_done
    jmp .sm_dispatch

;; .sm_star_to_i64(rax = payload, rdx = tag) -> rax = the number
;; CPython takes an int and nothing else here -- not a float, and not even an
;; object with __index__ -- and says "* wants int".
.sm_star_to_i64:
    push rcx
    mov rdi, rax
    call int_is_integer
    test eax, eax
    jz .sm_star_bad
    call int_unwrap             ; rdi, edx: a compact int flattens to a smallint
    cmp edx, TAG_SMALLINT
    jne .sm_star_big
    mov rax, rdi
    pop rcx
    ret
.sm_star_big:
    ; A width or precision that needs GMP is nonsense, but truncating it is
    ; still better than reading the pointer as a number.
    call int_to_i64
    pop rcx
    ret
.sm_star_bad:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "* wants int"
    jmp .sm_error

.sm_prec_overflow:
    extern exc_OverflowError_type
    lea rdi, [rel exc_OverflowError_type]
    CSTRING rsi, "Python int too large to convert to C int"
    jmp .sm_error

.sm_dispatch:
    ; In bytes mode every conversion takes the spec path, so the argument is
    ; converted in exactly one place.  %% is not a conversion and takes no
    ; argument, so it stays where it was.
    cmp qword [rbp-SM_ISBYTES], 0
    je .sm_dispatch_str
    movzx eax, byte [rbx + rcx]
    cmp al, '%'
    jne .sm_use_spec
    jmp .sm_dispatch_plain
.sm_dispatch_str:
    ; A '%' reaching here is not the literal `%%`: that is taken at the top of
    ; the directive, before any flag can have been read.  So it is a
    ; conversion letter, and there is no such conversion -- "%.2%" is an
    ; error in CPython, and used to come back here as a formatted number with
    ; a percent sign on it.
    movzx eax, byte [rbx + rcx]
    cmp al, '%'
    jne .sm_dispatch_spec_check
    movzx edi, al
    mov rsi, rcx
    jmp .sm_bad_conv
.sm_dispatch_spec_check:
    ; A directive carrying flags, width or precision was skipped outright,
    ; so "%5s" % "x" returned "x".  Those go through the format-spec engine;
    ; a bare %s or %d keeps the direct path below.
    mov rax, [rbp-SM_SPECST]
    cmp rax, rcx
    jne .sm_use_spec
    ; The direct path below never learned %X, %o or %b, so those went out
    ; literally even with no flags; and its %x handled only an int immediate,
    ; printing "0" for a heap int.  All four go through the spec engine.
    movzx eax, byte [rbx + rcx]
    cmp al, 'X'
    je .sm_use_spec
    cmp al, 'x'
    je .sm_use_spec
    cmp al, 'o'
    je .sm_use_spec
    cmp al, 'b'
    je .sm_use_spec
    ; %e, %g and their uppercase forms went out literally, and %f fell back
    ; to str(), so "%f" % 1.5 was "1.5" rather than "1.500000".
    cmp al, 'e'
    je .sm_use_spec
    cmp al, 'E'
    je .sm_use_spec
    cmp al, 'f'
    je .sm_use_spec
    cmp al, 'F'
    je .sm_use_spec
    cmp al, 'g'
    je .sm_use_spec
    cmp al, 'G'
    je .sm_use_spec
    ; d, i and u too, so that one place checks the argument against the
    ; conversion.  The direct path below could not: it formatted whatever it
    ; was handed, which is how "%d" % "x" came to answer 'x'.
    cmp al, 'd'
    je .sm_use_spec
    cmp al, 'i'
    je .sm_use_spec
    cmp al, 'u'
    je .sm_use_spec
    ; %a and %c had no handler at all: the dispatcher's unknown-conversion arm
    ; printed them literally and consumed no argument, so "%c" % (65,) came
    ; back as "%c" and then complained that an argument was left over.
    cmp al, 'a'
    je .sm_use_spec
    cmp al, 'c'
    je .sm_use_spec
    jmp .sm_dispatch_plain
.sm_use_spec:
    mov [rbp-SM_POS], rcx

    ; --- a bare %d, with nothing else to say ------------------------------
    ; Far and away the commonest directive, and it went through the whole
    ; format-spec machinery: a spec string assembled character by character
    ; and handed to format_apply_spec.  `"%s-%d" % ("abc", i)` cost four
    ; mallocs, and callgrind put str_mod_impl and format_apply_spec together
    ; at 19% of a loop of them.
    ;
    ; With no flags, no width and no precision there is nothing for a spec to
    ; say and int.__str__ is the whole answer.  What the spec path is really
    ; here for is the TYPE check -- %d was routed through it because the
    ; direct arm formatted whatever it was handed, and `"%d" % "x"` answered
    ; 'x'.  So the argument is fetched and inspected, and anything that is not
    ; an exact int is put back and goes the long way.
    ;
    ; A mapping key is excluded rather than handled: .sm_get_arg clears
    ; SM_HASKEY on its way past, so putting that argument back would take
    ; more than a `dec`.
    movzx eax, byte [rbx + rcx]
    cmp al, 'd'
    je .sm_bare_d_try
    cmp al, 'i'
    je .sm_bare_d_try
    cmp al, 'u'
    jne .sm_spec_general
.sm_bare_d_try:
    cmp qword [rbp-SM_HASKEY], 0
    jne .sm_spec_general
    mov rax, [rbp-SM_SPECST]
    cmp rax, rcx
    jne .sm_spec_general        ; flags, a width or a precision: not bare
    call .sm_get_arg            ; rax/edx = the argument, r15 advanced
    cmp edx, TAG_SMALLINT
    je .sm_bare_d_ok
    cmp edx, TAG_PTR
    jne .sm_bare_d_decline
    test rax, rax
    jz .sm_bare_d_decline
    mov rcx, [rax + PyObject.ob_type]
    lea r8, [rel int_type]
    cmp rcx, r8
    jne .sm_bare_d_decline      ; a bool, an int subclass, anything else
.sm_bare_d_ok:
    mov rcx, [rbp-SM_POS]
    inc rcx                     ; past the conversion character
    push rcx                    ; .sm_copy_str pops the input position
    mov rdi, rax
    mov rsi, rdx
    V_PACK rdi, rsi
    call obj_str                ; int.__str__ = int_repr
    jmp .sm_copy_str
.sm_bare_d_decline:
    dec r15                     ; put the argument back
    mov rcx, [rbp-SM_POS]

.sm_spec_general:
    call .sm_spec_conv
    mov rcx, [rbp-SM_POS]
    jmp .sm_loop

.sm_dispatch_plain:
    movzx eax, byte [rbx + rcx]
    inc rcx                    ; consume conversion char

    cmp al, 's'
    je .sm_str
    cmp al, 'd'
    je .sm_int
    cmp al, 'i'
    je .sm_int
    cmp al, 'r'
    je .sm_repr
    cmp al, 'f'
    je .sm_str                 ; %f: use str() for now (float.__str__)
    cmp al, 'x'
    je .sm_hex
    ; Unknown: CPython raises rather than echoing it.
    movzx edi, al
    lea rsi, [rcx - 1]
    jmp .sm_bad_conv

.sm_str:
    ; Get next arg
    push rcx
    call .sm_get_arg
    ; rax = arg payload, rdx = arg tag
    mov rdi, rax
    mov rsi, rdx               ; tag for obj_str
    V_PACK rdi, rsi
    call obj_str
    ; rax = str result
    jmp .sm_copy_str

.sm_int:
    push rcx
    call .sm_get_arg
    ; If TAG_BOOL, convert to TAG_SMALLINT so we get "0"/"1" not "False"/"True"
    ; If TAG_PTR pointing to bool_type, extract 0/1 as SmallInt
    cmp edx, TAG_PTR
    jne .sm_int_go
    test rax, rax
    jz .sm_int_go
    mov rcx, [rax + PyObject.ob_type]
    extern bool_type
    lea r8, [rel bool_type]
    cmp rcx, r8
    jne .sm_int_go
    ; bool singleton → extract 0/1 by comparing with bool_true
    extern bool_true
    lea rcx, [rel bool_true]
    xor edi, edi
    cmp rax, rcx
    setne dil                  ; wait, True=1 so sete
    xor edi, edi
    cmp rax, rcx
    sete dil                   ; rdi = 1 if True, 0 if False
    mov rax, rdi
    mov edx, TAG_SMALLINT
    jmp .sm_int_go
.sm_int_from_bool:
    ; TAG_BOOL payload is 0 or 1
    mov edx, TAG_SMALLINT
.sm_int_go:
    mov rdi, rax
    mov rsi, rdx               ; tag for obj_str (64-bit)
    V_PACK rdi, rsi
    call obj_str               ; int.__str__ = int_repr
    jmp .sm_copy_str

.sm_repr:
    push rcx
    call .sm_get_arg
    mov rdi, rax
    mov rsi, rdx               ; tag for obj_repr (64-bit)
    V_PACK rdi, rsi
    call obj_repr
    jmp .sm_copy_str

.sm_hex:
    ; %x: format integer as lowercase hex
    push rcx
    call .sm_get_arg
    ; Convert TAG_BOOL to TAG_SMALLINT
    ; Handle TAG_PTR bool singletons
    cmp edx, TAG_PTR
    jne .sm_hex_go
    test rax, rax
    jz .sm_hex_go
    mov rcx, [rax + PyObject.ob_type]
    lea r8, [rel bool_type]
    cmp rcx, r8
    jne .sm_hex_go
    lea rcx, [rel bool_true]
    xor edi, edi
    cmp rax, rcx
    sete dil
    mov rax, rdi
    mov edx, TAG_SMALLINT
    jmp .sm_hex_go
.sm_hex_from_bool:
    mov edx, TAG_SMALLINT
.sm_hex_go:
    ; Only handle SmallInt for now
    cmp edx, TAG_SMALLINT
    jne .sm_hex_zero
    mov rdi, rax               ; value
    ; Format into stack buffer (max 16 hex digits + null)
    sub rsp, 24                ; temp buffer
    mov rsi, rsp
    call .sm_format_hex        ; rsi = buffer, returns length in rax
    ; Copy result to output
    mov rcx, rax               ; length
    mov rsi, rsp               ; buffer
    lea rdi, [r14 + rcx + 1]
    push rcx
    push rsi
    call .sm_ensure_cap
    pop rsi
    pop rcx
    xor edx, edx
.sm_hex_copy:
    cmp rdx, rcx
    jge .sm_hex_done
    movzx eax, byte [rsi + rdx]
    mov [r13 + r14], al
    inc r14
    inc rdx
    jmp .sm_hex_copy
.sm_hex_done:
    add rsp, 24
    pop rcx
    jmp .sm_loop

.sm_hex_zero:
    ; Non-SmallInt: just output "0"
    lea rdi, [r14 + 2]
    call .sm_ensure_cap
    mov byte [r13 + r14], '0'
    inc r14
    pop rcx
    jmp .sm_loop

; .sm_format_hex: format unsigned int rdi as hex into buffer rsi
; Returns length in rax. Buffer must be >= 17 bytes.
.sm_format_hex:
    push rbx
    mov rax, rdi
    test rax, rax
    jnz .hex_nonzero
    mov byte [rsi], '0'
    mov eax, 1
    pop rbx
    ret
.hex_nonzero:
    ; Write digits in reverse into temp area, then reverse
    xor ecx, ecx              ; digit count
    mov rbx, rsi              ; save buffer start
    lea rdi, [rsi + 16]       ; write from end of temp area backward
.hex_digit_loop:
    test rax, rax
    jz .hex_reverse
    mov rdx, rax
    and edx, 0xf
    cmp dl, 10
    jb .hex_dec_digit
    add dl, ('a' - 10)
    jmp .hex_store
.hex_dec_digit:
    add dl, '0'
.hex_store:
    dec rdi
    mov [rdi], dl
    shr rax, 4
    inc ecx
    jmp .hex_digit_loop
.hex_reverse:
    ; Copy from [rdi] to [rbx], ecx chars
    mov rax, rcx               ; return length
    xor edx, edx
.hex_copy_loop:
    cmp edx, ecx
    jge .hex_fmt_done
    movzx esi, byte [rdi + rdx]
    mov [rbx + rdx], sil
    inc edx
    jmp .hex_copy_loop
.hex_fmt_done:
    pop rbx
    ret

.sm_copy_str:
    ; rax = str payload (heap PyStrObject*)
    test rax, rax
    jz .sm_conv_failed         ; obj_str/obj_repr raised: nothing to copy
    push rax                   ; save for DECREF
    mov rcx, [rax + PyStrObject.ob_size]
    lea rsi, [rax + PyStrObject.data]
    ; Ensure enough space for the entire string
    push rcx
    push rsi
    lea rdi, [r14 + rcx + 1]  ; need pos + len + 1 for null
    call .sm_ensure_cap
    pop rsi
    pop rcx
    ; Copy chars (memcpy-style)
    xor edx, edx
.sm_copy_loop:
    cmp rdx, rcx
    jge .sm_copy_done
    movzx eax, byte [rsi + rdx]
    mov [r13 + r14], al
    inc r14
    inc rdx
    jmp .sm_copy_loop
.sm_copy_done:
    pop rdi                    ; DECREF temp str
    DECREF_REG rdi
    pop rcx                    ; restore input pos
    jmp .sm_loop

.sm_get_arg:
    ; Get arg at index r15, increment r15
    ; Returns arg payload in rax, tag in rdx (borrowed ref)
    cmp qword [rbp-SM_HASKEY], 1
    jne .sm_arg_positional
    mov rax, [rbp-SM_KEYVAL]
    V_UNPACK rax, rdx
    mov qword [rbp-SM_HASKEY], 0
    ; CPython makes the keyed value the argument source and lets it be taken
    ; once: "%(a)*d" % {"a": 1} uses the 1 as the WIDTH and then has nothing
    ; left for the %d.  Without this the second fetch fell back to the mapping
    ; itself and complained about formatting a dict.  A mapping skips the
    ; arity check entirely, so counting here costs nothing else.
    inc r15
    ret
.sm_arg_positional:
    cmp qword [rbp-SM_ISTUPLE], 1
    je .sm_arg_tuple
    ; Single value.  A mapping counts as one too -- "%s" % {"a": 1} formats
    ; the dict -- but only once: a second unkeyed conversion has nothing left,
    ; which is what CPython reports as "not enough arguments".
    cmp qword [rbp-SM_ISMAP], 1
    jne .sm_arg_single
    test r15, r15
    jnz .sm_arg_none
.sm_arg_single:
    mov rax, [rbp-SM_ARGS]
    mov rdx, [rbp-SM_ATAG]
    inc r15
    ret
.sm_arg_tuple:
    mov rax, [rbp-SM_ARGS]     ; tuple
    mov rdx, r15
    cmp rdx, [rax + PyTupleObject.ob_size]
    jge .sm_arg_none
    mov rcx, [rax + PyTupleObject.ob_item]       ; payloads
    mov rax, [rcx + rdx*8]                       ; arg payload
    V_UNPACK rax, rdx
    inc r15
    ret
.sm_arg_none:
    ; Past the end of the argument list.  Substituting None here quietly
    ; formatted a missing argument as "None"; the format string is wrong and
    ; Python says so.
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "not enough arguments for format string"
    jmp .sm_error

;; .sm_ensure_cap — ensure buffer can hold rdi bytes total
;; rdi = required capacity. Preserves r14, r15, rbx, r12. Updates r13.
.sm_ensure_cap:
    cmp rdi, [rbp-SM_CAP]
    jbe .sm_cap_ok
    ; Double capacity until sufficient
    mov rax, [rbp-SM_CAP]
.sm_grow_loop:
    shl rax, 1
    cmp rdi, rax
    ja .sm_grow_loop
    ; rax = new capacity
    mov [rbp-SM_CAP], rax
    mov rdi, r13               ; old ptr
    mov rsi, rax               ; new size
    ; ALIGN, rather than assume.  This helper is reached from seven places at
    ; three different parities -- one push, two pushes, and none at all, some
    ; of them behind a jump that has already pushed -- so there is no single
    ; correction that is right for all of them, and no comment at any one
    ; site could stay true.  It passed its caller's parity straight through
    ; to ap_realloc, which reaches glibc realloc for any buffer past 512
    ; bytes; that was unreachable while the buffer started at 8 KB, and 256
    ; is what makes it live.  `and` costs one instruction and is right from
    ; anywhere.
    mov [rbp-SM_SAVERSP], rsp
    and rsp, -16
    call ap_realloc
    mov rsp, [rbp-SM_SAVERSP]
    mov r13, rax
    mov [rbp-SM_BUF], rax
.sm_cap_ok:
    ret

.sm_done:
    ; Every argument must have been consumed.  A single non-tuple value counts
    ; as one; a mapping is addressed by key and has no count to check.
    cmp qword [rbp-SM_HASKEY], 1
    je .sm_arity_ok
    cmp qword [rbp-SM_ISMAP], 1
    je .sm_arity_ok
    cmp r15, [rbp-SM_NARGS]
    jb .sm_too_many
.sm_arity_ok:

    ; Null-terminate and create string.  Guarded rather than assumed: every
    ; append above ensures room for what IT writes, and the terminator is one
    ; byte more than any of them asked for.  While the buffer started at 8 KB
    ; and doubled, the slack made that unreachable; it is one byte past the
    ; end of a block that fits exactly.
    lea rdi, [r14 + 1]
    call .sm_ensure_cap
    mov byte [r13 + r14], 0

    push r13                   ; save buffer ptr for free
    mov rdi, r13
    mov rsi, r14
    call str_new_heap
    mov rbx, rax               ; save result

    pop rdi                    ; free heap buffer
    call ap_free

    mov rax, rbx               ; return result
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    mov edx, TAG_PTR
    leave
    ret
.sm_too_many:
    ; "bytes formatting" when that is what it is: bytes_mod goes through this
    ; function, and the message it produced named the wrong type.
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "not all arguments converted during string formatting"
    cmp qword [rbp-SM_ISBYTES], 0
    je .sm_error
    CSTRING rsi, "not all arguments converted during bytes formatting"
    jmp .sm_error

.sm_key_unterminated:
    lea rdi, [rel exc_ValueError_type]
    CSTRING rsi, "incomplete format key"
    jmp .sm_error

;; .sm_bad_conv(rdi = the conversion character, rsi = its index) -- CPython's
;; wording, which names the character twice and says where it was.  Reached
;; from both dispatchers: the spec path validates against the table, and the
;; direct path used to print an unknown conversion LITERALLY and consume no
;; argument, so "%z" % (1,) answered "%z" and then complained about a leftover
;; argument.
.sm_bad_conv:
    push rdi
    push rsi
    lea rdi, [rel sm_convbuf]
    CSTRING rsi, "unsupported format character '"
    extern rbt_append_cstr
    call rbt_append_cstr
    mov rcx, [rsp + 8]
    mov [rax], cl
    inc rax
    mov rdi, rax
    CSTRING rsi, "' (0x"
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rsp + 8]
    extern msg_append_hex2
    call msg_append_hex2
    mov rdi, rax
    CSTRING rsi, ") at index "
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rsp]
    extern msg_append_i64
    call msg_append_i64
    mov byte [rax], 0
    add rsp, 16
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rel sm_convbuf]
    jmp .sm_error

.sm_key_error:
    ; CPython names the key that was missing, as an ordinary dict lookup does.
    ; A fixed message said only that one was.  The key object was released
    ; just above, so this re-reads it -- it is still allocated, and its only
    ; use here is the message.
    lea rsp, [rbp - SM_FRAME - 40]      ; as .sm_error does, and for the same
    mov rdi, [rbp-SM_KEYOBJ]           ; reason
    extern set_key_error
    call set_key_error
    mov rdi, [rbp-SM_BUF]
    test rdi, rdi
    jz .sm_ke_freed
    mov qword [rbp-SM_BUF], 0
    call ap_free
.sm_ke_freed:
    cmp qword [rbp-SM_NORAISE], 0
    jne .sm_error_ret           ; the caller reads the pending exception
    mov rdi, [gs:ThreadState.current_exception]
    mov qword [gs:ThreadState.current_exception], 0
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    extern raise_exception_obj
    jmp raise_exception_obj     ; takes the reference, does not return

;; A conversion's own call raised, and its exception is already pending.
;;
;; Every plain arm pushes the input position before the call and lets
;; .sm_copy_str pop it, and .sm_spec_conv is reached with a `call`, so the
;; stack is reset the way .sm_error resets it.  Unlike .sm_error there is
;; nothing to raise -- only the buffer to give back and the pending exception
;; to hand on.
;;
;; It has to hand it on by RAISING rather than by returning NULL: op_binary_op
;; reads a NULL Value from an nb_ slot as "this pair is not mine" and carries
;; on to the right operand's slot and then to a TypeError, which would bury
;; the exception the conversion actually raised.
.sm_conv_failed:
    lea rsp, [rbp - SM_FRAME - 40]      ; the five pushes, and nothing else
    mov rdi, [rbp-SM_BUF]
    test rdi, rdi
    jz .sm_cf_freed
    mov qword [rbp-SM_BUF], 0
    call ap_free
.sm_cf_freed:
    cmp qword [rbp-SM_NORAISE], 0
    jne .sm_error_ret           ; the caller reads the pending exception
    mov rdi, [gs:ThreadState.current_exception]
    mov qword [gs:ThreadState.current_exception], 0
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    jmp raise_exception_obj     ; takes the reference, does not return

;; The one way out.  rdi = the exception type, rsi = the message; the buffer
;; goes back either way, because a raise abandons this frame and the free
;; below with it.
.sm_error:
    ; Some of these sites are subroutines of this function, reached with a
    ; `call` -- so the return address is still on the stack, and popping the
    ; five saved registers over it put a return address in r15.  RAISE could
    ; ignore that, because it abandoned the whole stack; returning cannot.
    lea rsp, [rbp - SM_FRAME - 40]      ; the five pushes, and nothing else
    cmp qword [rbp-SM_NORAISE], 0
    jne .sm_error_set
    push rdi
    push rsi
    mov rdi, [rbp-SM_BUF]
    test rdi, rdi
    jz .sm_error_freed
    mov qword [rbp-SM_BUF], 0
    call ap_free
.sm_error_freed:
    pop rsi
    pop rdi
    extern raise_exception
    call raise_exception        ; does not return
    ud2
.sm_error_set:
    extern set_exception
    call set_exception
.sm_error_installed:
    mov rdi, [rbp-SM_BUF]
    test rdi, rdi
    jz .sm_error_ret
    mov qword [rbp-SM_BUF], 0
    call ap_free
.sm_error_ret:
    xor eax, eax
    xor edx, edx
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
;; Format one directive through format_apply_spec.  On entry SM_POS is the
;; index of the conversion character and SM_SPECST the start of the flags;
;; on exit SM_POS is just past it.  r13 (buffer), r14 (output position),
;; r15 (argument index), rbx and r12 belong to the caller's loop, so
;; everything here lives in frame slots.
.sm_spec_conv:
    mov r8, [rbp-SM_POS]
    movzx r9d, byte [rbx + r8]      ; the conversion character
    mov [rbp-SM_CONV], r9
    ; %i and %u are %d's spellings; format() knows only the one.  SM_CONV
    ; keeps the original, because the error messages name it.
    mov [rbp-SM_SPECCH], r9

    ; The conversions % understands.  Anything else was accepted and then
    ; formatted as though it had been %s, so `b"%z" % (1,)` answered b"1"
    ; where CPython raises and names the character.  %b is bytes' alone.
    push r8
    push r9
    lea rsi, [rel sm_convs]
    cmp qword [rbp-SM_ISBYTES], 0
    je .sm_sc_check
    lea rsi, [rel sm_convs_bytes]
.sm_sc_check:
    movzx ecx, r9b
.sm_sc_scan:
    movzx eax, byte [rsi]
    test al, al
    jz .sm_sc_bad
    cmp eax, ecx
    je .sm_sc_known
    inc rsi
    jmp .sm_sc_scan
.sm_sc_bad:
    mov rdi, [rsp]              ; the conversion character
    mov rsi, [rsp + 8]          ; its index in the format
    add rsp, 16
    jmp .sm_bad_conv
.sm_sc_known:
    pop r9
    pop r8

    cmp r9b, 'i'
    je .sm_sc_as_d
    cmp r9b, 'u'
    je .sm_sc_as_d
    cmp r9b, 'r'
    je .sm_sc_as_s
    cmp r9b, 'a'
    je .sm_sc_as_s
    cmp r9b, 'c'
    je .sm_sc_as_s
    cmp qword [rbp-SM_ISBYTES], 0
    je .sm_sc_conv_kept
    cmp r9b, 'b'
    je .sm_sc_as_s              ; %b is bytes', and only exists there
    cmp r9b, 's'
    je .sm_sc_as_s
    jmp .sm_sc_conv_kept
.sm_sc_as_d:
    mov qword [rbp-SM_SPECCH], 'd'
    jmp .sm_sc_conv_kept
.sm_sc_as_s:
    ; %r, %a and %c each build a string first; what is left is a str spec.
    mov qword [rbp-SM_SPECCH], 's'
.sm_sc_conv_kept:
    inc r8
    mov [rbp-SM_POS], r8

    ; Alignment first: '-' means left, and % right-aligns everything else,
    ; including strings -- unlike format(), whose default for str is left.
    lea rdi, [rbp-SM_SPEC]
    xor r10d, r10d
    mov rax, [rbp-SM_SPECST]
    xor r11d, r11d
.sm_sc_seek_minus:
    cmp rax, [rbp-SM_POS]
    jge .sm_sc_seek_done
    cmp byte [rbx + rax], '-'
    jne .sm_sc_seek_next
    mov r11d, 1
.sm_sc_seek_next:
    inc rax
    jmp .sm_sc_seek_minus
.sm_sc_seek_done:
    ; A '*' width that came out negative means left-alignment, as a literal
    ; '-' flag does: CPython's "%*d" % (-6, 42) is '42    '.
    cmp qword [rbp-SM_STARWON], 0
    je .sm_sc_align_from_flags
    cmp qword [rbp-SM_STARW], 0
    jge .sm_sc_align_from_flags
    mov r11d, 1
.sm_sc_align_from_flags:
    mov byte [rdi], '>'
    test r11d, r11d
    jz .sm_sc_numeric_zero
    mov byte [rdi], '<'
    jmp .sm_sc_align_done

.sm_sc_numeric_zero:
    ; A '0' flag on a numeric conversion pads between the sign and the
    ; digits, which is '=' alignment; '>' put the zeros in front of the sign,
    ; so "%05d" % -42 came out "00-42".
    mov rcx, [rbp-SM_CONV]
    cmp cl, 's'
    je .sm_sc_align_done
    cmp cl, 'r'
    je .sm_sc_align_done
    mov rax, [rbp-SM_SPECST]
.sm_sc_flagskip:
    cmp rax, [rbp-SM_POS]
    jge .sm_sc_align_done
    movzx ecx, byte [rbx + rax]
    cmp cl, '+'
    je .sm_sc_flagnext
    cmp cl, ' '
    je .sm_sc_flagnext
    cmp cl, '#'
    je .sm_sc_flagnext
    cmp cl, '0'
    jne .sm_sc_align_done
    mov byte [rdi], '='
    jmp .sm_sc_align_done
.sm_sc_flagnext:
    inc rax
    jmp .sm_sc_flagskip

.sm_sc_align_done:
    mov r10d, 1

    ; Then the flags, width and precision verbatim, minus the '-'.
    mov qword [rbp-SM_SAWDOT], 0
    mov rax, [rbp-SM_SPECST]
.sm_sc_copy:
    mov rcx, [rbp-SM_POS]
    dec rcx
    cmp rax, rcx
    jge .sm_sc_copy_done
    movzx ecx, byte [rbx + rax]
    cmp cl, '.'
    je .sm_sc_copy_dot
    cmp cl, '*'
    je .sm_sc_copy_star
    cmp cl, '-'
    je .sm_sc_copy_next
    ; A '0' flag means nothing for %s and %r; CPython pads those with spaces.
    cmp cl, '0'
    jne .sm_sc_copy_keep
    cmp r10d, 1
    jne .sm_sc_copy_keep        ; a digit of the width, not the flag
    mov rcx, [rbp-SM_CONV]
    cmp cl, 's'
    je .sm_sc_copy_next
    cmp cl, 'r'
    je .sm_sc_copy_next
    movzx ecx, byte [rbx + rax]
.sm_sc_copy_keep:
    cmp r10, 36                 ; the spec buffer is 40 bytes and grows up
    jge .sm_sc_copy_done
    mov [rdi + r10], cl
    inc r10
.sm_sc_copy_next:
    inc rax
    jmp .sm_sc_copy

.sm_sc_copy_dot:
    mov qword [rbp-SM_SAWDOT], 1
    jmp .sm_sc_copy_keep

;; A '*' in the source stands for a number taken from the argument list; the
;; format-spec engine downstream knows nothing about '*', so the digits go in
;; here.  Which of the two it is follows from whether the '.' has gone by.
.sm_sc_copy_star:
    push rax
    mov rax, [rbp-SM_STARW]
    cmp qword [rbp-SM_SAWDOT], 0
    je .sm_sc_star_have
    mov rax, [rbp-SM_STARP]
.sm_sc_star_have:
    ; The sign is not part of the spec: a negative width has already become
    ; left-alignment, and a negative precision has already become zero.
    test rax, rax
    jns .sm_sc_star_emit
    neg rax
.sm_sc_star_emit:
    push rbx
    push r12
    xor r12d, r12d              ; digits pushed
.sm_sc_star_split:
    xor edx, edx
    mov ebx, 10
    div rbx                     ; rax = quotient, rdx = digit
    add rdx, '0'
    push rdx
    inc r12
    test rax, rax
    jnz .sm_sc_star_split
.sm_sc_star_pop:
    pop rcx
    cmp r10, 36                 ; the spec buffer is 40 bytes and grows up
    jge .sm_sc_star_skip
    mov [rdi + r10], cl
    inc r10
.sm_sc_star_skip:
    dec r12
    jnz .sm_sc_star_pop
    pop r12
    pop rbx
    pop rax
    jmp .sm_sc_copy_next

.sm_sc_copy_done:

    ; The conversion letter, mapped onto a spec type.
    mov rcx, [rbp-SM_CONV]
    cmp cl, 'i'
    jne .sm_sc_not_i
    mov cl, 'd'
.sm_sc_not_i:
    cmp cl, 'r'
    jne .sm_sc_store_type
    mov cl, 's'                     ; repr is applied to the value below
.sm_sc_store_type:
    mov rcx, [rbp-SM_SPECCH]
    mov [rdi + r10], cl
    inc r10

    lea rdi, [rbp-SM_SPEC]
    mov rsi, r10
    call str_new_heap
    mov [rbp-SM_SPECOBJ], rax

    call .sm_get_arg
    V_PACK rax, rdx
    mov [rbp-SM_VALUE], rax
    mov qword [rbp-SM_OWNVAL], 0
    ; The three conversions a BYTES format spells differently come first: they
    ; take the argument as it is, and would not survive the numeric check.
    mov rcx, [rbp-SM_CONV]
    cmp qword [rbp-SM_ISBYTES], 0
    je .sm_sc_coerce
    cmp cl, 'b'
    je .sm_sc_bytes_like
    cmp cl, 's'
    je .sm_sc_bytes_like
    cmp cl, 'c'
    je .sm_sc_bytes_char

.sm_sc_coerce:
    ; The argument has to suit the conversion, and may need converting to it:
    ; %d takes a float and truncates, %f takes an int and widens, and both
    ; take anything offering __index__ or __float__.
    mov rdi, [rbp-SM_VALUE]
    mov rsi, [rbp-SM_CONV]
    extern fmt_percent_coerce
    call fmt_percent_coerce
    test rax, rax
    jz .sm_conv_failed          ; a raising __index__ or __float__
    mov [rbp-SM_VALUE], rax
    mov [rbp-SM_OWNVAL], rdx
    mov rcx, [rbp-SM_CONV]
    cmp cl, 'r'
    je .sm_sc_repr
    cmp cl, 'a'
    je .sm_sc_ascii
    cmp cl, 'c'
    je .sm_sc_char
    jmp .sm_sc_have_value_owned

.sm_sc_repr:
    mov rdi, [rbp-SM_VALUE]
    call obj_repr
    test rax, rax
    jz .sm_conv_failed
    V_UNPACK rax, rdx
    V_PACK rax, rdx
    mov [rbp-SM_VALUE], rax
    mov qword [rbp-SM_OWNVAL], 1
    jmp .sm_sc_format

.sm_sc_ascii:
    sub rsp, 16
    mov rax, [rbp-SM_VALUE]
    mov [rsp], rax
    mov rdi, rsp
    mov esi, 1
    extern builtin_ascii_fn
    call builtin_ascii_fn
    add rsp, 16
    test rax, rax
    jz .sm_conv_failed
    mov [rbp-SM_VALUE], rax
    mov qword [rbp-SM_OWNVAL], 1
    jmp .sm_sc_format

.sm_sc_char:
    ; An integer becomes the character it numbers; a one-character string is
    ; already the answer.  Anything else, including a longer string, is not.
    mov rdi, [rbp-SM_VALUE]
    V_TEST_PTR rdi, rcx
    ja .sm_sc_char_int
    mov rcx, [rdi + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    jne .sm_sc_char_int
    cmp qword [rdi + PyStrObject.ob_length], 1
    jne .sm_sc_char_bad
    INCREF rdi
    mov [rbp-SM_VALUE], rdi
    mov qword [rbp-SM_OWNVAL], 1
    jmp .sm_sc_format
.sm_sc_char_int:
    mov rdi, [rbp-SM_VALUE]
    V_UNPACK rdi, rdx
    extern int_is_integer
    call int_is_integer
    test eax, eax
    jz .sm_sc_char_bad
    ; The range check belongs HERE rather than to builtin_chr, because the two
    ; report it differently: chr() raises ValueError and `%c` raises
    ; OverflowError, with a message naming the conversion.  The bytes arm just
    ; below has always done its own for the same reason.
    mov rdi, [rbp-SM_VALUE]
    V_UNPACK rdi, rdx
    extern int_to_i64
    call int_to_i64
    test rax, rax
    js .sm_sc_char_range
    mov ecx, 0x110000
    cmp rax, rcx
    jge .sm_sc_char_range
    sub rsp, 16
    mov rax, [rbp-SM_VALUE]
    mov [rsp], rax
    mov rdi, rsp
    mov esi, 1
    extern builtin_chr
    call builtin_chr
    add rsp, 16
    V_PACK rax, rdx
    mov [rbp-SM_VALUE], rax
    mov qword [rbp-SM_OWNVAL], 1
    jmp .sm_sc_format
.sm_sc_char_range:
    RAISE exc_OverflowError_type, "%c arg not in range(0x110000)"
.sm_sc_char_bad:
    RAISE exc_TypeError_type, "%c requires int or char"

;; %s and %b on a BYTES format: the argument must be bytes-like, and its bytes
;; go in unchanged.  Decoding it as latin-1 makes a str whose code points are
;; its bytes; bytes_mod re-encodes the result the same way, so the round trip
;; is exact.
.sm_sc_bytes_like:
    mov rdi, [rbp-SM_VALUE]
    extern bytes_mod_as_str
    call bytes_mod_as_str
    test rax, rax
    jz .sm_sc_bytes_bad
    mov [rbp-SM_VALUE], rax
    mov qword [rbp-SM_OWNVAL], 1
    jmp .sm_sc_format
.sm_sc_bytes_bad:
    mov rsi, [rbp-SM_VALUE]
    CSTRING rdi, `%b requires a bytes-like object, or an object that implements __bytes__, not '\x01'`
    extern raise_type_error_with_name
    call raise_type_error_with_name

;; %c on a BYTES format: an integer in range(256), or a single byte.
.sm_sc_bytes_char:
    mov rdi, [rbp-SM_VALUE]
    V_TEST_PTR rdi, rcx
    ja .sm_sc_bc_int
    mov rcx, [rdi + PyObject.ob_type]
    extern bytes_type
    lea rdx, [rel bytes_type]
    cmp rcx, rdx
    jne .sm_sc_bc_int
    cmp qword [rdi + PyBytesObject.ob_size], 1
    jne .sm_sc_bc_bad
    movzx edi, byte [rdi + PyBytesObject.data]
    jmp .sm_sc_bc_from_cp
.sm_sc_bc_int:
    mov rdi, [rbp-SM_VALUE]
    V_UNPACK rdi, rdx
    call int_is_integer
    test eax, eax
    jz .sm_sc_bc_bad
    mov rdi, [rbp-SM_VALUE]
    V_UNPACK rdi, rdx
    extern int_to_i64
    call int_to_i64
    test rax, rax
    jl .sm_sc_bc_range
    cmp rax, 255
    ja .sm_sc_bc_range
    mov rdi, rax
.sm_sc_bc_from_cp:
    ; One code point, which the re-encode turns back into the byte it names.
    ; It has to go in as UTF-8: a raw 0xff is not a str, and the re-encode
    ; read it as the lead byte of a sequence -- b"%c" % 255 came out b"\xc0".
    sub rsp, 32
    mov eax, edi
    mov rdi, rsp
    extern ucase_utf8_put
    call ucase_utf8_put         ; ecx = bytes written
    movsxd rsi, ecx
    mov rdi, rsp
    call str_new_heap
    add rsp, 32
    mov [rbp-SM_VALUE], rax
    mov qword [rbp-SM_OWNVAL], 1
    jmp .sm_sc_format
.sm_sc_bc_bad:
    RAISE exc_TypeError_type, "%c requires an integer in range(256) or a single byte"
.sm_sc_bc_range:
    RAISE exc_OverflowError_type, "%c arg not in range(256)"

.sm_sc_have_value_owned:

.sm_sc_format:
    mov rdi, [rbp-SM_VALUE]
    mov rsi, [rbp-SM_SPECOBJ]
    ; printf mode: the two mini-languages agree except on what a precision
    ; means for an integer conversion, and this is the printf side.
    extern format_apply_spec_printf
    call format_apply_spec_printf
    V_UNPACK rax, rdx
    mov [rbp-SM_PIECE], rax

    mov rdi, [rbp-SM_SPECOBJ]
    call obj_decref
    cmp qword [rbp-SM_OWNVAL], 0
    je .sm_sc_no_own
    ; DECREF_V and not obj_decref: what the argument check hands back may be
    ; an int or a float IMMEDIATE -- "%d" % 3.9 truncates to one -- and
    ; obj_decref would dereference it as a pointer.
    mov rdi, [rbp-SM_VALUE]
    DECREF_V rdi, rsi
.sm_sc_no_own:
    ; format_apply_spec runs __format__, which can raise.  The test is here
    ; rather than at the call so that the spec object and the owned value are
    ; released either way.
    cmp qword [rbp-SM_PIECE], 0
    je .sm_conv_failed

    ; Append the piece to the caller's buffer, advancing its position.
    mov rax, [rbp-SM_PIECE]
    mov r8, [rax + PyStrObject.ob_size]
    lea rdi, [r14 + r8 + 1]     ; + the NUL .sm_done writes after the last piece
    call .sm_ensure_cap
    mov rax, [rbp-SM_PIECE]
    mov r8, [rax + PyStrObject.ob_size]
    lea rsi, [rax + PyStrObject.data]
    xor ecx, ecx
.sm_sc_append:
    cmp rcx, r8
    jge .sm_sc_appended
    movzx eax, byte [rsi + rcx]
    mov [r13 + r14], al
    inc r14
    inc rcx
    jmp .sm_sc_append
.sm_sc_appended:
    mov rdi, [rbp-SM_PIECE]
    call obj_decref
    ret

END_FUNC str_mod_impl


;; ============================================================================
;; str_mod_subscript(rdi = the mapping, rsi = the key str) -> rax = Value, or 0
;;
;; `"%(a)s" % m` for any m with an mp_subscript, not only a dict -- the same
;; widening the operand classification got.  A dict keeps the direct lookup:
;; dict_get answers 0 for a miss where dict's own mp_subscript raises KeyError,
;; and str_mod's caller wants the former.
;;
;; The reference this hands back is borrowed for a dict and owned for anything
;; else, and str_mod treats it as borrowed throughout -- so a mapping of one's
;; own leaks one reference per key.  Releasing it here is not possible: the
;; value is read long after, and a raise anywhere between abandons the stack.
;; ============================================================================
DEF_FUNC_LOCAL str_mod_subscript
    mov rax, [rdi + PyObject.ob_type]
    extern dict_type
    lea rcx, [rel dict_type]
    cmp rax, rcx
    je .sms_dict
    REQUIRE_DICT_TYPE rax, rcx, .sms_generic
.sms_dict:
    extern dict_get
    call dict_get
    leave
    ret
.sms_generic:
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_mapping]
    test rax, rax
    jz .sms_none
    mov rax, [rax + PyMappingMethods.mp_subscript]
    test rax, rax
    jz .sms_none
    call rax
    leave
    ret
.sms_none:
    xor eax, eax
    leave
    ret
END_FUNC str_mod_subscript
