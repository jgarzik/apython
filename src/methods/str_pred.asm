; methods/str_pred.asm - str: the is* predicates, case mapping, justification
;
; Also count, index and rfind, which sit with them because the predicates and
; the searches share the same code-point walk.
;
; Methods are registered into each type's tp_dict by methods_init, in
; methods_init.asm.  A method is name(PyObject *self, PyObject **args,
; int64_t nargs); args are borrowed, the result is a new reference.

%include "macros.inc"
%include "object.inc"
extern eval_exception_unwind
extern obj_as_index
%include "opcodes.inc"


; External functions
extern str_search_window
extern ap_memfind
extern str_byte_to_cp
extern str_find_impl
extern ap_malloc
extern ap_free
extern ap_memcpy
extern ap_memset
extern str_new_heap
extern bool_true
extern bool_false
extern int_from_i64
extern int_to_i64
extern raise_exception
extern exc_TypeError_type
extern str_byte_to_cp
extern str_type

; Set entry layout constants (must match set.asm)

; --- moved to a sibling file by the split ---

section .data
align 8
; The default fill for center, ljust and rjust: a str of one space, so the
; builder always has a str object to copy from rather than a bare byte.
; Static, and never released -- nothing hands it out.
str_pad_space:
    dq 1                        ; ob_refcnt
    dq str_type                 ; ob_type
    dq 1                        ; ob_size, in bytes
    dq -1                       ; ob_hash
    dq 1                        ; ob_length, in code points
    db " ", 0, 0, 0, 0, 0, 0, 0

section .text

;; ============================================================================
;; str_method_count(args, nargs) -> SmallInt count of occurrences
;; args[0]=self, args[1]=sub
;; ============================================================================
;; start and end were ignored and the scan used the C-string ap_strstr, so
;; "abcabc".count("b", 3) was 2 and "a\x00b".count("b") was 0.  Counting an
;; empty needle over a window gives one position per code point plus one, which
;; is what CPython reports.
CNT_ARGS  equ 8
CNT_NARGS equ 16
CNT_SELF  equ 24
CNT_N     equ 32
CNT_WPTR  equ 56            ; the 3-word window: 56, 48, 40
CNT_WLEN  equ 48
CNT_WOFF  equ 40
CNT_FRAME equ 64            ; + 2 pushes = 80
DEF_FUNC str_method_count, CNT_FRAME
    push rbx
    push r12
    mov [rbp - CNT_ARGS], rdi
    mov [rbp - CNT_NARGS], rsi

    mov rax, [rdi + 8]              ; args[1]
    V_TEST_PTR rax, rcx
    ja .count_type_error
    mov rcx, [rax + PyObject.ob_type]
    REQUIRE_STR_TYPE rcx, rdx, .count_type_error

    mov rcx, [rdi]
    mov [rbp - CNT_SELF], rcx
    mov qword [rbp - CNT_N], 0

    mov rdi, rcx
    mov rsi, [rbp - CNT_ARGS]
    mov rdx, [rbp - CNT_NARGS]
    lea rcx, [rbp - CNT_WPTR]
    call str_search_window
    test eax, eax
    jz .count_done                  ; nothing can match: zero

    mov rbx, [rbp - CNT_WPTR]       ; rbx = cursor into the window
    mov r12, [rbp - CNT_WLEN]       ; r12 = bytes left

    mov rax, [rbp - CNT_ARGS]
    mov rax, [rax + 8]
    mov rax, [rax + PyStrObject.ob_size]
    test rax, rax
    jz .count_empty_sub

.count_scan:
    mov rdi, rbx
    mov rsi, r12
    mov rdx, [rbp - CNT_ARGS]
    mov rdx, [rdx + 8]
    mov rcx, [rdx + PyStrObject.ob_size]
    lea rdx, [rdx + PyStrObject.data]
    call ap_memfind
    test rax, rax
    jz .count_done

    inc qword [rbp - CNT_N]
    ; Advance past the match; non-overlapping, as CPython counts.
    mov rdx, [rbp - CNT_ARGS]
    mov rdx, [rdx + 8]
    mov rdx, [rdx + PyStrObject.ob_size]
    add rax, rdx
    sub r12, rax
    add r12, rbx                    ; bytes left = old_left - (rax - rbx)
    mov rbx, rax
    jmp .count_scan

.count_empty_sub:
    ; One position before each code point in the window, plus one at the end.
    mov rdi, [rbp - CNT_SELF]
    mov rax, [rdi + PyStrObject.ob_size]
    cmp rax, [rdi + PyStrObject.ob_length]
    jne .count_empty_walk
    mov rax, r12                    ; ASCII: one code point per byte
    inc rax
    mov [rbp - CNT_N], rax
    jmp .count_done
.count_empty_walk:
    ; Non-ASCII: convert both ends of the window to code point indices.
    mov rsi, [rbp - CNT_WOFF]
    call str_byte_to_cp
    mov rbx, rax
    mov rdi, [rbp - CNT_SELF]
    mov rsi, [rbp - CNT_WOFF]
    add rsi, r12
    call str_byte_to_cp
    sub rax, rbx
    inc rax
    mov [rbp - CNT_N], rax

.count_done:
    mov rdi, [rbp - CNT_N]
    call int_from_i64
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.count_type_error:
    ; The offending object is still in rax: neither the tag test nor
    ; REQUIRE_STR_TYPE touches it, and CPython names its type.
    mov rsi, rax
    CSTRING rdi, `must be str, not \x01`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name
END_FUNC str_method_count

;; ============================================================================
;; str_method_index(args, nargs) -> SmallInt index (raises ValueError if not found)
;; args[0]=self, args[1]=substr
;; ============================================================================
DEF_FUNC_BARE str_method_index
    mov edx, 2                  ; forward, raise on a miss
    jmp str_find_impl
END_FUNC str_method_index

;; ============================================================================
;; str_method_rfind(args, nargs) -> SmallInt index or -1
;; args[0]=self, args[1]=substr
;; Find rightmost occurrence of substr in self.
;; ============================================================================
DEF_FUNC_BARE str_method_rfind
    mov edx, 1                  ; reverse
    jmp str_find_impl
END_FUNC str_method_rfind

;; ============================================================================
;; str_method_isdigit(args, nargs) -> bool_true/bool_false
;; args[0] = self
;; Returns True if all chars are digits and len>0, else False
;; ============================================================================
DEF_FUNC str_method_isdigit
    ; str_pred_impl in methods/str_case.asm, over the same generated flag
    ; table the case mappings read.
    mov rdi, [rdi]
    mov esi, 2
    extern str_pred_impl
    call str_pred_impl
    RET_BOOL_RAX
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC str_method_isdigit


;; ============================================================================
;; str_method_isidentifier / isprintable / isascii / isdecimal / isnumeric
;;
;; ASCII-only, like the rest of the str predicates here: a str is still a byte
;; string, so a non-ASCII byte can only be reported honestly as "not one of
;; these".  isidentifier is what functools, enum, dataclasses and textwrap all
;; reach for; the other four keep the family complete.
;; ============================================================================
DEF_FUNC str_method_isidentifier
    ; str_pred_impl in methods/str_case.asm, over the same generated flag
    ; table the case mappings read.
    mov rdi, [rdi]
    mov esi, 10
    extern str_pred_impl
    call str_pred_impl
    RET_BOOL_RAX
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC str_method_isidentifier

;; Every byte printable and not a space-only string; the empty string is True.
DEF_FUNC str_method_isprintable
    ; str_pred_impl in methods/str_case.asm, over the same generated flag
    ; table the case mappings read.
    mov rdi, [rdi]
    mov esi, 9
    extern str_pred_impl
    call str_pred_impl
    RET_BOOL_RAX
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC str_method_isprintable

DEF_FUNC str_method_isascii
    ; str_pred_impl in methods/str_case.asm, over the same generated flag
    ; table the case mappings read.
    mov rdi, [rdi]
    mov esi, 11
    extern str_pred_impl
    call str_pred_impl
    RET_BOOL_RAX
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC str_method_isascii

;; isdecimal and isnumeric agree with isdigit over ASCII, which is all a byte
;; string can represent.
DEF_FUNC str_method_isdecimal
    ; str_pred_impl in methods/str_case.asm, over the same generated flag
    ; table the case mappings read.
    mov rdi, [rdi]
    mov esi, 1
    extern str_pred_impl
    call str_pred_impl
    RET_BOOL_RAX
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC str_method_isdecimal

DEF_FUNC str_method_isnumeric
    ; str_pred_impl in methods/str_case.asm, over the same generated flag
    ; table the case mappings read.
    mov rdi, [rdi]
    mov esi, 3
    extern str_pred_impl
    call str_pred_impl
    RET_BOOL_RAX
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC str_method_isnumeric

;; ============================================================================
;; str_method_isalpha(args, nargs) -> bool_true/bool_false
;; args[0] = self
;; Returns True if all chars are alphabetic and len>0, else False
;; ============================================================================
DEF_FUNC str_method_isalpha
    ; str_pred_impl in methods/str_case.asm, over the same generated flag
    ; table the case mappings read.
    mov rdi, [rdi]
    xor esi, esi
    extern str_pred_impl
    call str_pred_impl
    RET_BOOL_RAX
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC str_method_isalpha

;; ============================================================================
;; str_method_isalnum(args, nargs) -> bool_true/bool_false
;; args[0] = self
;; Returns True if all chars are alphanumeric (0-9, A-Z, a-z) and len>0
;; ============================================================================
DEF_FUNC str_method_isalnum
    ; str_pred_impl in methods/str_case.asm, over the same generated flag
    ; table the case mappings read.
    mov rdi, [rdi]
    mov esi, 4
    extern str_pred_impl
    call str_pred_impl
    RET_BOOL_RAX
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC str_method_isalnum

;; ============================================================================
;; str_method_isspace(args, nargs) -> bool_true/bool_false
;; args[0] = self
;; Returns True if all chars are whitespace (space/tab/newline/CR/VT/FF) and len>0
;; ============================================================================
DEF_FUNC str_method_isspace
    ; str_pred_impl in methods/str_case.asm, over the same generated flag
    ; table the case mappings read.
    mov rdi, [rdi]
    mov esi, 5
    extern str_pred_impl
    call str_pred_impl
    RET_BOOL_RAX
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC str_method_isspace

;; ============================================================================
;; str_method_isupper(args, nargs) -> bool_true/bool_false
;; args[0] = self
;; Returns True if all cased chars are uppercase, and there is at least one cased char
;; ============================================================================
DEF_FUNC str_method_isupper
    ; str_pred_impl in methods/str_case.asm, over the same generated flag
    ; table the case mappings read.
    mov rdi, [rdi]
    mov esi, 6
    extern str_pred_impl
    call str_pred_impl
    RET_BOOL_RAX
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC str_method_isupper

;; ============================================================================
;; str_method_islower(args, nargs) -> bool_true/bool_false
;; args[0] = self
;; Returns True if all cased chars are lowercase, and there is at least one cased char
;; ============================================================================
DEF_FUNC str_method_islower
    ; str_pred_impl in methods/str_case.asm, over the same generated flag
    ; table the case mappings read.
    mov rdi, [rdi]
    mov esi, 7
    extern str_pred_impl
    call str_pred_impl
    RET_BOOL_RAX
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC str_method_islower

;; ============================================================================
;; str_method_title(args, nargs) -> new titlecased string
;; Uppercase after non-alpha, lowercase after alpha
;; ============================================================================
DEF_FUNC str_method_title
    ; The whole of it is str_case_map in methods/str_case.asm: the six differ
    ; only in which of the four Unicode mappings each character takes.
    mov rax, [rdi]
    mov rdi, rax
    mov esi, 2
    extern str_case_map
    call str_case_map
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC str_method_title

;; ============================================================================
;; str_method_capitalize(args, nargs) -> new string
;; First char upper, rest lower
;; ============================================================================
DEF_FUNC str_method_capitalize
    ; The whole of it is str_case_map in methods/str_case.asm: the six differ
    ; only in which of the four Unicode mappings each character takes.
    mov rax, [rdi]
    mov rdi, rax
    mov esi, 3
    extern str_case_map
    call str_case_map
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC str_method_capitalize

;; ============================================================================
;; str_method_swapcase(args, nargs) -> new string
;; Upper→lower, lower→upper
;; ============================================================================
DEF_FUNC str_method_swapcase
    ; The whole of it is str_case_map in methods/str_case.asm: the six differ
    ; only in which of the four Unicode mappings each character takes.
    mov rax, [rdi]
    mov rdi, rax
    mov esi, 4
    extern str_case_map
    call str_case_map
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC str_method_swapcase

;; ============================================================================
;; str_method_casefold(args, nargs) -> new string
;; ASCII casefold = lowercase (full Unicode casefold deferred)
;; ============================================================================
DEF_FUNC str_method_casefold
    ; The whole of it is str_case_map in methods/str_case.asm: the six differ
    ; only in which of the four Unicode mappings each character takes.
    mov rax, [rdi]
    mov rdi, rax
    mov esi, 5
    extern str_case_map
    call str_case_map
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC str_method_casefold

;; ============================================================================
;; str_fill_char(rdi = the fillchar argument, a Value) -> rax = it, as a str
;;
;; CPython's rule for center, ljust and rjust: exactly one character, and a
;; str.  Neither half was checked -- the byte at the object's PyStrObject.data
;; offset was read whatever the object was, so `"abc".center(0, 0)` read a
;; small integer's Value as a pointer and died, `"abc".center(10, "xy")`
;; padded with 'x', and `"abc".center(10, None)` padded with whatever byte sat
;; at that offset in the None singleton.
;;
;; Does not return on failure.
;; ============================================================================
SFC_ARG   equ 8
SFC_FRAME equ 16            ; + 0 pushes = 16-aligned
DEF_FUNC str_fill_char, SFC_FRAME
    mov [rbp - SFC_ARG], rdi
    V_TEST_PTR rdi, rax
    ja .sfc_not_str
    test rdi, rdi
    jz .sfc_not_str
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    je .sfc_have_str
    mov rax, [rax + PyTypeObject.tp_flags]
    test rax, TYPE_FLAG_STR_SUBCLASS
    jz .sfc_not_str
.sfc_have_str:
    cmp qword [rdi + PyStrObject.ob_length], 1
    jne .sfc_bad_length
    mov rax, rdi
    leave
    ret

.sfc_not_str:
    mov rsi, [rbp - SFC_ARG]
    CSTRING rdi, `The fill character must be a unicode character, not \x01`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name
.sfc_bad_length:
    RAISE exc_TypeError_type, \
          "The fill character must be exactly one character long"
END_FUNC str_fill_char

;; ============================================================================
;; str_pad_width(rdi = the width argument, a Value; esi = 0 for a value that
;;               has to fit a C ssize_t, 1 for one that has to fit a C int)
;;   -> rax = it, as an i64
;;
;; A width is an index, and may be any object with __index__ -- but it also
;; has to FIT one: obj_as_index truncates, so `"abc".center(2**70)` came back
;; as "abc" where CPython raises.  The two limits are CPython's own, and it
;; words them apart: a width is an ssize_t and expandtabs' tabsize an int.
;; ============================================================================
SPW_ARG   equ 8
SPW_MODE  equ 16
SPW_FRAME equ 32            ; + 0 pushes = 16-aligned
DEF_FUNC str_pad_width, SPW_FRAME
    mov [rbp - SPW_MODE], rsi
    mov [rbp - SPW_ARG], rdi
    extern int_is_integer
    V_UNPACK rdi, rdx
    push rdi
    push rdx
    call int_is_integer
    pop rdx
    pop rdi
    test eax, eax
    jz .spw_index
    extern int_fits_i64
    push rdi
    push rdx
    call int_fits_i64
    pop rdx
    pop rdi
    test eax, eax
    jz .spw_overflow
.spw_index:
    mov rdi, [rbp - SPW_ARG]
    V_UNPACK rdi, rdx
    call obj_as_index
    ERR_M1_JUMP
    cmp qword [rbp - SPW_MODE], 0
    je .spw_done
    cmp rax, 0x7FFFFFFF
    jg .spw_overflow
    cmp rax, -0x80000000
    jl .spw_overflow
.spw_done:
    leave
    ret
.spw_overflow:
    extern exc_OverflowError_type
    cmp qword [rbp - SPW_MODE], 0
    jne .spw_overflow_int
    RAISE exc_OverflowError_type, "Python int too large to convert to C ssize_t"
.spw_overflow_int:
    RAISE exc_OverflowError_type, "Python int too large to convert to C int"
END_FUNC str_pad_width

;; ============================================================================
;; str_pad_build(rdi = the string, rsi = pad characters on the left,
;;               rdx = pad characters on the right, rcx = the fill, a str)
;;   -> (rax = the padded string, rdx = TAG_PTR), or 0 on failure
;;
;; One builder for center, ljust and rjust.  Each used to memset its own
;; buffer with a single BYTE, so a fill outside ASCII -- `"abc".center(10,
;; "\u00e9")`, which CPython pads with e-acute -- wrote the first byte of its
;; UTF-8 ten times and produced a string that is not valid UTF-8 at all.
;; ============================================================================
SPB_SELF  equ 8
SPB_LEFT  equ 16
SPB_RIGHT equ 24
SPB_FILL  equ 32
SPB_OUT   equ 40
SPB_FRAME equ 56            ; + 1 push = 64, 16-aligned
DEF_FUNC str_pad_build, SPB_FRAME
    push rbx
    mov [rbp - SPB_SELF], rdi
    mov [rbp - SPB_LEFT], rsi
    mov [rbp - SPB_RIGHT], rdx
    mov [rbp - SPB_FILL], rcx

    ; bytes = self's bytes + (left + right) * the fill's bytes
    mov rax, [rbp - SPB_LEFT]
    add rax, [rbp - SPB_RIGHT]
    mov rcx, [rbp - SPB_FILL]
    imul rax, [rcx + PyStrObject.ob_size]
    add rax, [rdi + PyStrObject.ob_size]
    mov rbx, rax                    ; rbx = the byte count

    lea rdi, [rbx + PyStrObject.data + 1]
    call ap_malloc
    mov [rbp - SPB_OUT], rax
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel str_type]
    mov [rax + PyObject.ob_type], rcx
    mov qword [rax + PyStrObject.ob_hash], -1
    mov [rax + PyStrObject.ob_size], rbx
    ; The length in CODE POINTS is the padding plus the string's own, which
    ; is not the byte count once the fill is outside ASCII.
    mov rcx, [rbp - SPB_LEFT]
    add rcx, [rbp - SPB_RIGHT]
    mov rdx, [rbp - SPB_SELF]
    add rcx, [rdx + PyStrObject.ob_length]
    mov [rax + PyStrObject.ob_length], rcx
    mov byte [rax + PyStrObject.data + rbx], 0

    lea rbx, [rax + PyStrObject.data]   ; rbx = the write cursor
    mov rsi, [rbp - SPB_LEFT]
.spb_left_loop:
    test rsi, rsi
    jz .spb_left_done
    push rsi
    mov rdi, rbx
    mov rcx, [rbp - SPB_FILL]
    lea rsi, [rcx + PyStrObject.data]
    mov rdx, [rcx + PyStrObject.ob_size]
    add rbx, rdx
    call ap_memcpy
    pop rsi
    dec rsi
    jmp .spb_left_loop
.spb_left_done:

    mov rdi, rbx
    mov rcx, [rbp - SPB_SELF]
    lea rsi, [rcx + PyStrObject.data]
    mov rdx, [rcx + PyStrObject.ob_size]
    add rbx, rdx
    call ap_memcpy

    mov rsi, [rbp - SPB_RIGHT]
.spb_right_loop:
    test rsi, rsi
    jz .spb_right_done
    push rsi
    mov rdi, rbx
    mov rcx, [rbp - SPB_FILL]
    lea rsi, [rcx + PyStrObject.data]
    mov rdx, [rcx + PyStrObject.ob_size]
    add rbx, rdx
    call ap_memcpy
    pop rsi
    dec rsi
    jmp .spb_right_loop
.spb_right_done:

    mov rax, [rbp - SPB_OUT]
    mov edx, TAG_PTR
    pop rbx
    leave
    ret
END_FUNC str_pad_build

;; ============================================================================
;; str_method_center(args, nargs) -> new centered string
;; args[0]=self, args[1]=width, args[2]=fillchar (optional, default ' ')
;; ============================================================================
PA_SELF   equ 8
PA_LEN    equ 16            ; length in bytes, for the copies
PA_ARGS   equ 24
PA_NARGS  equ 32
PA_CPLEN  equ 40            ; length in code points, which is what a width means
PA_FRAME  equ 56            ; + 3 pushes = 80, 16-aligned
DEF_FUNC str_method_center, PA_FRAME
    push rbx
    push r12
    push r13

    mov [rbp - PA_ARGS], rdi
    mov [rbp - PA_NARGS], rsi
    mov rbx, [rdi]                      ; self
    mov [rbp - PA_SELF], rbx
    mov rax, [rbx + PyStrObject.ob_length]
    mov [rbp - PA_CPLEN], rax

    mov rax, [rbp - PA_ARGS]
    mov rdi, [rax + 8]                  ; args[1], the width
    extern str_pad_width
    xor esi, esi                        ; a width has to fit a C ssize_t
    call str_pad_width
    mov r13, rax

    ; The fill, which has to be one character and a str.  Reading a byte off
    ; whatever object arrived is what made `"abc".center(0, 0)` a segfault.
    lea r12, [rel str_pad_space]
    cmp qword [rbp - PA_NARGS], 3
    jl .center_have_fill
    mov rax, [rbp - PA_ARGS]
    mov rdi, [rax + 16]                 ; args[2]
    extern str_fill_char
    call str_fill_char
    mov r12, rax
.center_have_fill:

    mov rax, r13                        ; the width, before it becomes the margin
    sub r13, [rbp - PA_CPLEN]           ; the padding, in characters
    jle .center_return_self

    ; CPython's unicode_center is `left = marg/2 + (marg & width & 1)`, so the
    ; odd character goes on the LEFT, and only when the width is odd as well:
    ; "ab".center(3) is "*ab" and "ab".center(6) is "**ab**".  Halving alone
    ; put it on the right, and bytes.center had the rule right -- so str and
    ; bytes disagreed with each other about the same call.
    and rax, r13
    and rax, 1
    mov rdi, [rbp - PA_SELF]
    mov rsi, r13
    shr rsi, 1
    add rsi, rax                        ; the left pad
    mov rdx, r13
    sub rdx, rsi                        ; and the rest on the right
    mov rcx, r12
    extern str_pad_build
    call str_pad_build
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.center_return_self:
    mov rbx, [rbp - PA_SELF]
    lea rdi, [rbx + PyStrObject.data]
    mov rsi, [rbx + PyStrObject.ob_size]
    call str_new_heap
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC str_method_center

;; ============================================================================
;; str_method_ljust(args, nargs) -> left-justified string
;; args[0]=self, args[1]=width, args[2]=fillchar (optional, default ' ')
;; ============================================================================
DEF_FUNC str_method_ljust, PA_FRAME
    push rbx
    push r12
    push r13

    mov [rbp - PA_ARGS], rdi
    mov [rbp - PA_NARGS], rsi
    mov rbx, [rdi]                      ; self
    mov [rbp - PA_SELF], rbx
    mov rax, [rbx + PyStrObject.ob_length]
    mov [rbp - PA_CPLEN], rax

    mov rax, [rbp - PA_ARGS]
    mov rdi, [rax + 8]                  ; args[1], the width
    extern str_pad_width
    xor esi, esi                        ; a width has to fit a C ssize_t
    call str_pad_width
    mov r13, rax

    ; The fill, which has to be one character and a str.  Reading a byte off
    ; whatever object arrived is what made `"abc".ljust(0, 0)` a segfault.
    lea r12, [rel str_pad_space]
    cmp qword [rbp - PA_NARGS], 3
    jl .ljust_have_fill
    mov rax, [rbp - PA_ARGS]
    mov rdi, [rax + 16]                 ; args[2]
    extern str_fill_char
    call str_fill_char
    mov r12, rax
.ljust_have_fill:

    sub r13, [rbp - PA_CPLEN]           ; the padding, in characters
    jle .ljust_return_self

    mov rdi, [rbp - PA_SELF]
    xor esi, esi
    mov rdx, r13
    mov rcx, r12
    extern str_pad_build
    call str_pad_build
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.ljust_return_self:
    mov rbx, [rbp - PA_SELF]
    lea rdi, [rbx + PyStrObject.data]
    mov rsi, [rbx + PyStrObject.ob_size]
    call str_new_heap
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC str_method_ljust

;; ============================================================================
;; str_method_rjust(args, nargs) -> right-justified string
;; ============================================================================
DEF_FUNC str_method_rjust, PA_FRAME
    push rbx
    push r12
    push r13

    mov [rbp - PA_ARGS], rdi
    mov [rbp - PA_NARGS], rsi
    mov rbx, [rdi]                      ; self
    mov [rbp - PA_SELF], rbx
    mov rax, [rbx + PyStrObject.ob_length]
    mov [rbp - PA_CPLEN], rax

    mov rax, [rbp - PA_ARGS]
    mov rdi, [rax + 8]                  ; args[1], the width
    extern str_pad_width
    xor esi, esi                        ; a width has to fit a C ssize_t
    call str_pad_width
    mov r13, rax

    ; The fill, which has to be one character and a str.  Reading a byte off
    ; whatever object arrived is what made `"abc".rjust(0, 0)` a segfault.
    lea r12, [rel str_pad_space]
    cmp qword [rbp - PA_NARGS], 3
    jl .rjust_have_fill
    mov rax, [rbp - PA_ARGS]
    mov rdi, [rax + 16]                 ; args[2]
    extern str_fill_char
    call str_fill_char
    mov r12, rax
.rjust_have_fill:

    sub r13, [rbp - PA_CPLEN]           ; the padding, in characters
    jle .rjust_return_self

    mov rdi, [rbp - PA_SELF]
    mov rsi, r13
    xor edx, edx
    mov rcx, r12
    extern str_pad_build
    call str_pad_build
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.rjust_return_self:
    mov rbx, [rbp - PA_SELF]
    lea rdi, [rbx + PyStrObject.data]
    mov rsi, [rbx + PyStrObject.ob_size]
    call str_new_heap
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC str_method_rjust

;; ============================================================================
;; str_method_zfill(args, nargs) -> zero-filled string
;; args[0]=self, args[1]=width
;; ============================================================================
DEF_FUNC str_method_zfill, PA_FRAME
    push rbx
    push r12
    push r13

    mov [rbp - PA_ARGS], rdi
    mov rbx, [rdi]
    mov r12, [rbx + PyStrObject.ob_size]
    mov [rbp - PA_SELF], rbx
    mov [rbp - PA_LEN], r12
    mov rax, [rbx + PyStrObject.ob_length]
    mov [rbp - PA_CPLEN], rax

    mov rax, [rbp - PA_ARGS]
    mov rdi, [rax + 8]                  ; args[1], the width
    xor esi, esi
    call str_pad_width                  ; an index, and one that FITS one:
    mov r13, rax                        ; obj_as_index alone truncates

    cmp r13, [rbp - PA_CPLEN]
    jle .zfill_return_self
    sub r13, [rbp - PA_CPLEN]
    add r13, r12

    ; Allocate filled with '0'
    mov rdi, r13
    call ap_malloc
    mov rbx, rax
    mov rdi, rbx
    mov esi, '0'
    mov rdx, r13
    call ap_memset
    mov rdi, rbx
    mov rsi, r13
    call str_new_heap
    push rax
    mov rdi, rbx
    call ap_free
    pop r13

    ; Copy self at end
    mov rbx, [rbp - PA_SELF]
    mov r12, [rbp - PA_LEN]
    mov rcx, [r13 + PyStrObject.ob_size]
    sub rcx, r12
    ; Check for sign prefix: '+' or '-' at position 0 of self
    test r12, r12
    jz .zfill_no_sign
    movzx eax, byte [rbx + PyStrObject.data]
    cmp al, '-'
    je .zfill_sign
    cmp al, '+'
    je .zfill_sign
.zfill_no_sign:
    lea rdi, [r13 + PyStrObject.data + rcx]
    lea rsi, [rbx + PyStrObject.data]
    mov rdx, r12
    call ap_memcpy
    jmp .zfill_done
.zfill_sign:
    ; Move sign to position 0, copy digits (skip sign) after zeros
    mov [r13 + PyStrObject.data], al
    lea rdi, [r13 + PyStrObject.data + rcx + 1]  ; after padding + sign
    lea rsi, [rbx + PyStrObject.data + 1]          ; skip sign in source
    mov rdx, r12
    dec rdx                                         ; len - 1
    call ap_memcpy
.zfill_done:
    mov rax, r13
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.zfill_return_self:
    lea rdi, [rbx + PyStrObject.data]
    mov rsi, r12
    call str_new_heap
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC str_method_zfill
