; methods/bytes_str.asm - the string-shaped bytes and bytearray methods
;
; The case mappings, the is* predicates, justification, splitlines, expandtabs,
; translate, maketrans and the two affix removals.  They are ASCII-only by
; definition: CPython's bytes methods are, because a bytes has no encoding to
; consult, so b'\xe9'.upper() is b'\xe9' in both interpreters and no Unicode
; table belongs here.
;
; Every body reads its subject through bytes_like_ptr_len and answers with a
; bytes.  bytearray reaches them through bytearray_shared_call
; (methods/bytes.asm), which converts the result back where CPython's answers
; with a bytearray.
;
; Methods are registered into each type's tp_dict by methods_init, in
; methods/init.asm.  A method is name(PyObject **args, int64_t nargs); args
; are borrowed and args[0] is self, the result is a new reference.

%include "macros.inc"
%include "object.inc"
extern obj_is_true
%include "opcodes.inc"


extern bytes_like_ptr_len
extern bytes_from_data
extern bytes_new
extern bytes_type
extern obj_as_index
extern obj_decref
extern ap_memcpy
extern ap_memset
extern list_new
extern list_append
extern bool_true
extern bool_false
extern none_singleton
extern set_exception
extern exc_TypeError_type
extern exc_ValueError_type
extern exc_MemoryError_type

section .text

;; ============================================================================
;; bs_arg_i64(rdi = a Value) -> rax = the integer it denotes
;; Fails: -1
;; ============================================================================
DEF_FUNC_LOCAL bs_arg_i64
    V_UNPACK rdi, rdx
    call obj_as_index           ; err: its -1 and exception are this function's own
    leave
    ret
END_FUNC bs_arg_i64

;; ============================================================================
;; BS_SUBJECT args_slot, data_slot, len_slot, bad_label
;;
;; The prologue every one of these shares: args into a frame slot, then
;; args[0] through bytes_like_ptr_len into two more.  A slot rather than a
;; push, so that every call below stays on a 16-byte rsp.
;; ============================================================================
%macro BS_SUBJECT 4             ; %1 args, %2 data, %3 len, %4 = the bad label
    test rsi, rsi
    jz %4
    mov [rbp - %1], rdi
    mov rdi, [rdi]
    call bytes_like_ptr_len
    test ecx, ecx
    jz %4
    mov [rbp - %2], rax
    mov [rbp - %3], r10
%endmacro


;; ############################################################################
;;                       CASE MAPPING
;; ############################################################################

;; ============================================================================
;; bytes_case_impl(rdi = args, rsi = nargs, edx = mode) -> a new bytes
;;   mode 0 upper, 1 lower, 2 swapcase, 3 capitalize, 4 title
;;
;; The output is the input's length in every mode -- there is no bytes
;; equivalent of str's SS-for-eszett, so copy-then-transform-in-place is safe
;; here in a way it would not be for str.
;; Fails: 0
;; ============================================================================
BCS_ARGS  equ 8
BCS_DATA  equ 16
BCS_LEN   equ 24
BCS_MODE  equ 32
BCS_FRAME equ 48            ; + 0 pushes = 48

DEF_FUNC bytes_case_impl, BCS_FRAME
    mov [rbp - BCS_MODE], rdx
    BS_SUBJECT BCS_ARGS, BCS_DATA, BCS_LEN, .bcs_type

    mov rdi, [rbp - BCS_DATA]
    mov rsi, [rbp - BCS_LEN]
    call bytes_from_data
    test rax, rax
    jz .bcs_oom

    lea r8, [rax + PyBytesObject.data]
    mov r9, [rbp - BCS_LEN]
    mov rdx, [rbp - BCS_MODE]
    xor r11d, r11d              ; index
    xor r10d, r10d              ; title: the previous byte was a letter
.bcs_loop:
    cmp r11, r9
    jge .bcs_done
    movzx ecx, byte [r8 + r11]
    cmp rdx, 3
    je .bcs_cap
    cmp rdx, 4
    je .bcs_title
    cmp rdx, 2
    je .bcs_swap
    cmp rdx, 1
    je .bcs_to_lower
.bcs_to_upper:
    cmp cl, 'a'
    jb .bcs_store
    cmp cl, 'z'
    ja .bcs_store
    sub cl, 32
    jmp .bcs_store
.bcs_to_lower:
    cmp cl, 'A'
    jb .bcs_store
    cmp cl, 'Z'
    ja .bcs_store
    add cl, 32
    jmp .bcs_store
.bcs_swap:
    cmp cl, 'a'
    jb .bcs_swap_up
    cmp cl, 'z'
    ja .bcs_store
    sub cl, 32
    jmp .bcs_store
.bcs_swap_up:
    cmp cl, 'A'
    jb .bcs_store
    cmp cl, 'Z'
    ja .bcs_store
    add cl, 32
    jmp .bcs_store
.bcs_cap:
    test r11, r11
    jz .bcs_to_upper
    jmp .bcs_to_lower
.bcs_title:
    ; A word starts after anything that is not a letter.
    movzx eax, cl
    or  al, 0x20                ; fold the case away, for the test only
    cmp al, 'a'
    jb .bcs_title_other
    cmp al, 'z'
    ja .bcs_title_other
    test r10b, r10b
    mov r10b, 1
    jnz .bcs_to_lower
    jmp .bcs_to_upper
.bcs_title_other:
    xor r10d, r10d
    jmp .bcs_store
.bcs_store:
    mov [r8 + r11], cl
    inc r11
    jmp .bcs_loop

.bcs_done:
    lea rax, [r8 - PyBytesObject.data]
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret

.bcs_type:
    SET_EXC exc_TypeError_type, "a bytes-like object is required"
    xor eax, eax
    leave
    ret
.bcs_oom:
    SET_EXC exc_MemoryError_type, "out of memory"
    xor eax, eax
    leave
    ret
END_FUNC bytes_case_impl

DEF_FUNC_BARE bytes_method_upper
    xor edx, edx
    jmp bytes_case_impl
END_FUNC bytes_method_upper

DEF_FUNC_BARE bytes_method_lower
    mov edx, 1
    jmp bytes_case_impl
END_FUNC bytes_method_lower

DEF_FUNC_BARE bytes_method_swapcase
    mov edx, 2
    jmp bytes_case_impl
END_FUNC bytes_method_swapcase

DEF_FUNC_BARE bytes_method_capitalize
    mov edx, 3
    jmp bytes_case_impl
END_FUNC bytes_method_capitalize

DEF_FUNC_BARE bytes_method_title
    mov edx, 4
    jmp bytes_case_impl
END_FUNC bytes_method_title


;; ############################################################################
;;                       THE is* PREDICATES
;; ############################################################################

;; ============================================================================
;; bytes_pred_impl(rdi = args, rsi = nargs, edx = kind) -> True / False
;;   0 isalpha, 1 isdigit, 2 isspace, 3 isalnum, 4 isascii,
;;   5 isupper, 6 islower, 7 istitle
;;
;; The first four are false on an empty bytes and isascii is true on one --
;; that asymmetry is CPython's, not an oversight here.
;; Fails: 0
;; ============================================================================
BPR_ARGS  equ 8
BPR_DATA  equ 16
BPR_LEN   equ 24
BPR_KIND  equ 32
BPR_FRAME equ 48            ; + 0 pushes = 48

DEF_FUNC bytes_pred_impl, BPR_FRAME
    mov [rbp - BPR_KIND], rdx
    BS_SUBJECT BPR_ARGS, BPR_DATA, BPR_LEN, .bpr_type

    mov r8, [rbp - BPR_DATA]
    mov r9, [rbp - BPR_LEN]
    mov rdx, [rbp - BPR_KIND]
    xor r11d, r11d

    cmp edx, 4
    je .bpr_ascii
    cmp edx, 5
    je .bpr_isupper
    cmp edx, 6
    je .bpr_islower
    cmp edx, 7
    je .bpr_istitle

    test r9, r9
    jz .bpr_false
.bpr_class_loop:
    cmp r11, r9
    jge .bpr_true
    movzx ecx, byte [r8 + r11]
    cmp edx, 1
    je .bpr_c_digit
    cmp edx, 2
    je .bpr_c_space
    cmp edx, 3
    je .bpr_c_alnum
.bpr_c_alpha:
    or  cl, 0x20
    cmp cl, 'a'
    jb .bpr_false
    cmp cl, 'z'
    ja .bpr_false
    jmp .bpr_c_next
.bpr_c_digit:
    cmp cl, '0'
    jb .bpr_false
    cmp cl, '9'
    ja .bpr_false
    jmp .bpr_c_next
.bpr_c_space:
    cmp cl, ' '
    je .bpr_c_next
    cmp cl, 9
    jb .bpr_false
    cmp cl, 13
    ja .bpr_false
    jmp .bpr_c_next
.bpr_c_alnum:
    cmp cl, '0'
    jb .bpr_c_alnum_alpha
    cmp cl, '9'
    jbe .bpr_c_next
.bpr_c_alnum_alpha:
    or  cl, 0x20
    cmp cl, 'a'
    jb .bpr_false
    cmp cl, 'z'
    ja .bpr_false
.bpr_c_next:
    inc r11
    jmp .bpr_class_loop

.bpr_ascii:
    cmp r11, r9
    jge .bpr_true
    cmp byte [r8 + r11], 0x80
    jae .bpr_false
    inc r11
    jmp .bpr_ascii

.bpr_isupper:
    xor r10d, r10d              ; a cased byte has been seen
.bpr_isupper_loop:
    cmp r11, r9
    jge .bpr_cased_end
    movzx ecx, byte [r8 + r11]
    cmp cl, 'a'
    jb .bpr_isupper_chk
    cmp cl, 'z'
    jbe .bpr_false
.bpr_isupper_chk:
    cmp cl, 'A'
    jb .bpr_isupper_next
    cmp cl, 'Z'
    ja .bpr_isupper_next
    mov r10d, 1
.bpr_isupper_next:
    inc r11
    jmp .bpr_isupper_loop

.bpr_islower:
    xor r10d, r10d
.bpr_islower_loop:
    cmp r11, r9
    jge .bpr_cased_end
    movzx ecx, byte [r8 + r11]
    cmp cl, 'A'
    jb .bpr_islower_chk
    cmp cl, 'Z'
    jbe .bpr_false
.bpr_islower_chk:
    cmp cl, 'a'
    jb .bpr_islower_next
    cmp cl, 'z'
    ja .bpr_islower_next
    mov r10d, 1
.bpr_islower_next:
    inc r11
    jmp .bpr_islower_loop

.bpr_cased_end:
    test r10d, r10d
    jz .bpr_false
    jmp .bpr_true

;; Every uppercase byte must open a word and every lowercase byte must
;; continue one, and at least one of them has to be there.
.bpr_istitle:
    xor r10d, r10d              ; a cased byte has been seen
    xor edx, edx                ; the previous byte was cased
.bpr_istitle_loop:
    cmp r11, r9
    jge .bpr_cased_end
    movzx ecx, byte [r8 + r11]
    cmp cl, 'A'
    jb .bpr_ist_low
    cmp cl, 'Z'
    ja .bpr_ist_low
    test edx, edx
    jnz .bpr_false
    mov edx, 1
    mov r10d, 1
    jmp .bpr_ist_next
.bpr_ist_low:
    cmp cl, 'a'
    jb .bpr_ist_uncased
    cmp cl, 'z'
    ja .bpr_ist_uncased
    test edx, edx
    jz .bpr_false
    mov r10d, 1
    jmp .bpr_ist_next
.bpr_ist_uncased:
    xor edx, edx
.bpr_ist_next:
    inc r11
    jmp .bpr_istitle_loop

.bpr_true:
    RET_TRUE
    leave
    V_PACK rax, rdx
    ret
.bpr_false:
    RET_FALSE
    leave
    V_PACK rax, rdx
    ret
.bpr_type:
    SET_EXC exc_TypeError_type, "a bytes-like object is required"
    xor eax, eax
    leave
    ret
END_FUNC bytes_pred_impl

DEF_FUNC_BARE bytes_method_isalpha
    xor edx, edx
    jmp bytes_pred_impl
END_FUNC bytes_method_isalpha

DEF_FUNC_BARE bytes_method_isdigit
    mov edx, 1
    jmp bytes_pred_impl
END_FUNC bytes_method_isdigit

DEF_FUNC_BARE bytes_method_isspace
    mov edx, 2
    jmp bytes_pred_impl
END_FUNC bytes_method_isspace

DEF_FUNC_BARE bytes_method_isalnum
    mov edx, 3
    jmp bytes_pred_impl
END_FUNC bytes_method_isalnum

DEF_FUNC_BARE bytes_method_isascii
    mov edx, 4
    jmp bytes_pred_impl
END_FUNC bytes_method_isascii

DEF_FUNC_BARE bytes_method_isupper
    mov edx, 5
    jmp bytes_pred_impl
END_FUNC bytes_method_isupper

DEF_FUNC_BARE bytes_method_islower
    mov edx, 6
    jmp bytes_pred_impl
END_FUNC bytes_method_islower

DEF_FUNC_BARE bytes_method_istitle
    mov edx, 7
    jmp bytes_pred_impl
END_FUNC bytes_method_istitle


;; ############################################################################
;;                       JUSTIFICATION
;; ############################################################################

;; ============================================================================
;; bytes_just_impl(rdi = args, rsi = nargs, edx = mode) -> a new bytes
;;   mode 0 ljust, 1 rjust, 2 center
;;
;; center's split is CPython's exactly -- left = marg/2 + (marg & width & 1) --
;; which is what puts the odd byte of b'ab'.center(5) on the right and the odd
;; byte of b'abc'.center(6) on the left.
;; Fails: 0
;; ============================================================================
BJU_ARGS  equ 8
BJU_DATA  equ 16
BJU_LEN   equ 24
BJU_MODE  equ 32
BJU_WIDTH equ 40
BJU_OBJ   equ 48
BJU_LEFT  equ 56
BJU_FILL  equ 64
BJU_FRAME equ 80            ; + 0 pushes = 80

DEF_FUNC bytes_just_impl, BJU_FRAME
    mov [rbp - BJU_MODE], rdx
    cmp rsi, 2
    jl .bju_args
    cmp rsi, 3
    jg .bju_args
    mov [rbp - BJU_FILL], rsi   ; nargs, until the fill byte displaces it
    BS_SUBJECT BJU_ARGS, BJU_DATA, BJU_LEN, .bju_type

    mov rcx, [rbp - BJU_FILL]
    mov qword [rbp - BJU_FILL], ' '
    cmp rcx, 3
    jl .bju_have_fill
    mov rdi, [rbp - BJU_ARGS]
    mov rdi, [rdi + 16]
    call bytes_like_ptr_len
    test ecx, ecx
    jz .bju_fill_bad
    cmp r10, 1
    jne .bju_fill_bad
    movzx ecx, byte [rax]
    mov [rbp - BJU_FILL], rcx
.bju_have_fill:

    mov rdi, [rbp - BJU_ARGS]
    mov rdi, [rdi + 8]
    call bs_arg_i64
    ERR_M1 .bju_fail
    mov [rbp - BJU_WIDTH], rax

    sub rax, [rbp - BJU_LEN]
    jle .bju_copy               ; nothing to pad, but still a fresh object

    ; marg = width - len, and the mode decides how it splits.
    mov r9, rax                 ; marg
    xor r8d, r8d                ; the left pad
    cmp qword [rbp - BJU_MODE], 1
    je .bju_right
    cmp qword [rbp - BJU_MODE], 2
    je .bju_center
    jmp .bju_have_split
.bju_right:
    mov r8, r9
    jmp .bju_have_split
.bju_center:
    mov r8, r9
    shr r8, 1
    mov rcx, r9
    and rcx, [rbp - BJU_WIDTH]
    and rcx, 1
    add r8, rcx
.bju_have_split:
    mov [rbp - BJU_LEFT], r8

    mov rdi, [rbp - BJU_WIDTH]
    call bytes_new
    test rax, rax
    jz .bju_oom
    mov [rbp - BJU_OBJ], rax

    ; Fill the whole buffer, then drop the subject into place: one memset
    ; rather than two, and the right-hand pad needs no arithmetic of its own.
    lea rdi, [rax + PyBytesObject.data]
    mov rsi, [rbp - BJU_FILL]
    mov rdx, [rbp - BJU_WIDTH]
    call ap_memset

    mov rdi, [rbp - BJU_OBJ]
    lea rdi, [rdi + PyBytesObject.data]
    add rdi, [rbp - BJU_LEFT]
    mov rsi, [rbp - BJU_DATA]
    mov rdx, [rbp - BJU_LEN]
    call ap_memcpy

    mov rax, [rbp - BJU_OBJ]
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret

.bju_copy:
    mov rdi, [rbp - BJU_DATA]
    mov rsi, [rbp - BJU_LEN]
    call bytes_from_data
    test rax, rax
    jz .bju_oom
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret

.bju_type:
    SET_EXC exc_TypeError_type, "a bytes-like object is required"
    xor eax, eax
    leave
    ret
.bju_fill_bad:
    ; CPython names the method and the type it was handed: "center() argument
    ; 2 must be a byte string of length 1, not int".  Both halves were
    ; missing, and the two wordings this had drew a line -- wrong type
    ; against wrong length -- that CPython does not.
    mov rax, [rbp - BJU_MODE]
    lea rdi, [rel bju_msg_ljust]
    test rax, rax
    jz .bju_fill_msg
    lea rdi, [rel bju_msg_rjust]
    cmp rax, 1
    je .bju_fill_msg
    lea rdi, [rel bju_msg_center]
.bju_fill_msg:
    mov rsi, [rbp - BJU_ARGS]
    mov rsi, [rsi + 16]
    extern none_singleton
    lea rcx, [rel none_singleton]
    cmp rsi, rcx
    je .bju_fill_none           ; the clinic says "None", not "NoneType"
    extern set_type_error_with_name
    call set_type_error_with_name
    xor eax, eax
    leave
    ret
.bju_fill_none:
    ; The same three messages with the type name already in them; the
    ; composer would have written NoneType.
    mov rax, [rbp - BJU_MODE]
    lea rsi, [rel bju_msg_ljust_none]
    test rax, rax
    jz .bju_fill_none_raise
    lea rsi, [rel bju_msg_rjust_none]
    cmp rax, 1
    je .bju_fill_none_raise
    lea rsi, [rel bju_msg_center_none]
.bju_fill_none_raise:
    lea rdi, [rel exc_TypeError_type]
    call set_exception
    xor eax, eax
    leave
    ret
.bju_args:
    SET_EXC exc_TypeError_type, "takes at least 1 argument"
    xor eax, eax
    leave
    ret
.bju_oom:
    SET_EXC exc_MemoryError_type, "out of memory"
    xor eax, eax
    leave
    ret
.bju_fail:
    xor eax, eax
    leave
    ret
END_FUNC bytes_just_impl

section .rodata
bju_msg_ljust:  db `ljust() argument 2 must be a byte string of length 1, not \x01`, 0
bju_msg_rjust:  db `rjust() argument 2 must be a byte string of length 1, not \x01`, 0
bju_msg_center: db `center() argument 2 must be a byte string of length 1, not \x01`, 0
bju_msg_ljust_none:  db "ljust() argument 2 must be a byte string of length 1, not None", 0
bju_msg_rjust_none:  db "rjust() argument 2 must be a byte string of length 1, not None", 0
bju_msg_center_none: db "center() argument 2 must be a byte string of length 1, not None", 0
section .text

DEF_FUNC_BARE bytes_method_ljust
    xor edx, edx
    jmp bytes_just_impl
END_FUNC bytes_method_ljust

DEF_FUNC_BARE bytes_method_rjust
    mov edx, 1
    jmp bytes_just_impl
END_FUNC bytes_method_rjust

DEF_FUNC_BARE bytes_method_center
    mov edx, 2
    jmp bytes_just_impl
END_FUNC bytes_method_center


;; ============================================================================
;; bytes_method_zfill(args, nargs) -> a new bytes
;;
;; Zeroes on the left, except that a leading '+' or '-' stays in front of
;; them: b'-5'.zfill(4) is b'-005', not b'00-5'.
;; Fails: 0
;; ============================================================================
BZF_ARGS  equ 8
BZF_DATA  equ 16
BZF_LEN   equ 24
BZF_WIDTH equ 32
BZF_OBJ   equ 40
BZF_FILL  equ 48
BZF_FRAME equ 64            ; + 0 pushes = 64

DEF_FUNC bytes_method_zfill, BZF_FRAME
    cmp rsi, 2
    jne .bzf_args
    BS_SUBJECT BZF_ARGS, BZF_DATA, BZF_LEN, .bzf_type

    mov rdi, [rbp - BZF_ARGS]
    mov rdi, [rdi + 8]
    call bs_arg_i64
    ERR_M1 .bzf_fail
    mov [rbp - BZF_WIDTH], rax

    sub rax, [rbp - BZF_LEN]
    jg .bzf_pad
    mov rdi, [rbp - BZF_DATA]
    mov rsi, [rbp - BZF_LEN]
    call bytes_from_data
    test rax, rax
    jz .bzf_oom
    jmp .bzf_out

.bzf_pad:
    mov [rbp - BZF_FILL], rax   ; the number of zeroes
    mov rdi, [rbp - BZF_WIDTH]
    call bytes_new
    test rax, rax
    jz .bzf_oom
    mov [rbp - BZF_OBJ], rax

    lea rdi, [rax + PyBytesObject.data]
    mov esi, '0'
    mov rdx, [rbp - BZF_FILL]
    call ap_memset

    mov rdi, [rbp - BZF_OBJ]
    lea rdi, [rdi + PyBytesObject.data]
    add rdi, [rbp - BZF_FILL]
    mov rsi, [rbp - BZF_DATA]
    mov rdx, [rbp - BZF_LEN]
    call ap_memcpy

    mov rax, [rbp - BZF_OBJ]
    ; A sign that ended up behind the zeroes moves to the front.
    cmp qword [rbp - BZF_LEN], 0
    je .bzf_out
    mov r9, [rbp - BZF_FILL]
    movzx ecx, byte [rax + PyBytesObject.data + r9]
    cmp cl, '+'
    je .bzf_sign
    cmp cl, '-'
    jne .bzf_out
.bzf_sign:
    mov [rax + PyBytesObject.data], cl
    mov byte [rax + PyBytesObject.data + r9], '0'

.bzf_out:
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret

.bzf_type:
    SET_EXC exc_TypeError_type, "a bytes-like object is required"
    xor eax, eax
    leave
    ret
.bzf_args:
    SET_EXC exc_TypeError_type, "zfill() takes exactly one argument"
    xor eax, eax
    leave
    ret
.bzf_oom:
    SET_EXC exc_MemoryError_type, "out of memory"
    xor eax, eax
    leave
    ret
.bzf_fail:
    xor eax, eax
    leave
    ret
END_FUNC bytes_method_zfill


;; ============================================================================
;; bytes_method_expandtabs(args, nargs) -> a new bytes
;;
;; Two walks over the subject: the first sizes the result, the second fills
;; it.  A tab advances to the next multiple of tabsize *from the last line
;; break*, which is why the column is tracked rather than the index.
;; Fails: 0
;; ============================================================================
BET_ARGS  equ 8
BET_DATA  equ 16
BET_LEN   equ 24
BET_TABS  equ 32
BET_ACC   equ 40
BET_OBJ   equ 48
BET_FRAME equ 64            ; + 0 pushes = 64

DEF_FUNC bytes_method_expandtabs, BET_FRAME
    cmp rsi, 1
    jl .bet_args
    cmp rsi, 2
    jg .bet_args
    mov [rbp - BET_TABS], rsi   ; nargs, until the tab size displaces it
    BS_SUBJECT BET_ARGS, BET_DATA, BET_LEN, .bet_type

    mov rcx, [rbp - BET_TABS]
    mov qword [rbp - BET_TABS], 8
    cmp rcx, 2
    jl .bet_have_tabs
    mov rdi, [rbp - BET_ARGS]
    mov rdi, [rdi + 8]
    mov esi, 1                  ; a tabsize is a C int in CPython, and it
    extern str_pad_width        ; says so when handed one that will not fit;
    call str_pad_width          ; bs_arg_i64 truncated, so 2**31 tabs became
    ERR_M1 .bet_fail            ; the low half of one
    mov [rbp - BET_TABS], rax
.bet_have_tabs:

    ; Walk one: the size.
    mov r8, [rbp - BET_DATA]
    mov r9, [rbp - BET_LEN]
    mov r10, [rbp - BET_TABS]
    xor r11d, r11d              ; index
    xor eax, eax                ; the output size
    xor esi, esi                ; the column
.bet_size_loop:
    cmp r11, r9
    jge .bet_sized
    movzx ecx, byte [r8 + r11]
    cmp cl, 9
    je .bet_size_tab
    inc rax
    cmp cl, 10
    je .bet_size_break
    cmp cl, 13
    je .bet_size_break
    inc rsi
    jmp .bet_size_next
.bet_size_break:
    xor esi, esi
    jmp .bet_size_next
.bet_size_tab:
    test r10, r10
    jle .bet_size_next          ; tabsize <= 0 deletes the tab
    mov [rbp - BET_ACC], rax
    mov rax, rsi
    xor edx, edx
    div r10                     ; rdx = column % tabsize
    mov rcx, r10
    sub rcx, rdx                ; the advance
    mov rax, [rbp - BET_ACC]
    add rax, rcx
    add rsi, rcx
.bet_size_next:
    inc r11
    jmp .bet_size_loop
.bet_sized:

    mov rdi, rax
    call bytes_new
    test rax, rax
    jz .bet_oom
    mov [rbp - BET_OBJ], rax

    ; Walk two: the same steps, writing this time.
    lea r8, [rax + PyBytesObject.data]
    mov rdi, [rbp - BET_DATA]
    mov r9, [rbp - BET_LEN]
    mov r10, [rbp - BET_TABS]
    xor r11d, r11d              ; index into the subject
    xor esi, esi                ; the column
    xor eax, eax                ; index into the output
.bet_fill_loop:
    cmp r11, r9
    jge .bet_filled
    movzx ecx, byte [rdi + r11]
    cmp cl, 9
    je .bet_fill_tab
    mov [r8 + rax], cl
    inc rax
    cmp cl, 10
    je .bet_fill_break
    cmp cl, 13
    je .bet_fill_break
    inc rsi
    jmp .bet_fill_next
.bet_fill_break:
    xor esi, esi
    jmp .bet_fill_next
.bet_fill_tab:
    test r10, r10
    jle .bet_fill_next
    mov [rbp - BET_ACC], rax
    mov rax, rsi
    xor edx, edx
    div r10
    mov rcx, r10
    sub rcx, rdx                ; the advance
    mov rax, [rbp - BET_ACC]
    add rsi, rcx
.bet_fill_spaces:
    mov byte [r8 + rax], ' '
    inc rax
    dec rcx
    jnz .bet_fill_spaces
.bet_fill_next:
    inc r11
    jmp .bet_fill_loop
.bet_filled:
    mov rax, [rbp - BET_OBJ]
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret

.bet_type:
    SET_EXC exc_TypeError_type, "a bytes-like object is required"
    xor eax, eax
    leave
    ret
.bet_args:
    SET_EXC exc_TypeError_type, "expandtabs() takes at most 1 argument"
    xor eax, eax
    leave
    ret
.bet_oom:
    SET_EXC exc_MemoryError_type, "out of memory"
    xor eax, eax
    leave
    ret
.bet_fail:
    xor eax, eax
    leave
    ret
END_FUNC bytes_method_expandtabs


;; ============================================================================
;; bytes_method_splitlines(args, nargs) -> a list of bytes
;;
;; A bytes knows three line breaks and no more: \n, \r and \r\n.  str's \v,
;; \f, \x1c-\x1e and \x85 are Unicode line breaks, and a bytes has no encoding
;; that would make them so.
;; Fails: 0
;; ============================================================================
BSL_KEEP  equ 8
BSL_NEXT  equ 16
BSL_FRAME equ 24            ; + 5 pushes = 64

DEF_FUNC bytes_method_splitlines, BSL_FRAME
    push rbx
    push r12
    push r13
    push r14
    push r15

    cmp rsi, 1
    jl .bsl_args
    cmp rsi, 2
    jg .bsl_args
    mov r15, rdi                ; args

    ; keepends is a truth value, not an index: CPython takes anything and
    ; asks whether it is true, so splitlines("x") splits with the ends kept
    ; rather than raising about a str.
    mov qword [rbp - BSL_KEEP], 0
    cmp rsi, 2
    jl .bsl_have_keep
    mov rdi, [r15 + 8]
    call obj_is_true
    movsx rax, eax
    mov [rbp - BSL_KEEP], rax
.bsl_have_keep:

    mov rdi, [r15]
    call bytes_like_ptr_len
    test ecx, ecx
    jz .bsl_type
    mov rbx, rax                ; the data
    mov r12, r10                ; its length

    xor edi, edi
    call list_new
    test rax, rax
    jz .bsl_oom
    mov r14, rax

    xor r13d, r13d              ; the start of the next line
.bsl_loop:
    cmp r13, r12
    jge .bsl_done
    mov r15, r13                ; the scan cursor; args are done with
.bsl_scan:
    cmp r15, r12
    jge .bsl_at_end
    movzx ecx, byte [rbx + r15]
    cmp cl, 10
    je .bsl_break_lf
    cmp cl, 13
    je .bsl_break_cr
    inc r15
    jmp .bsl_scan
.bsl_break_cr:
    lea rax, [r15 + 1]
    cmp rax, r12
    jge .bsl_break_have
    cmp byte [rbx + rax], 10
    jne .bsl_break_have
    inc rax                     ; \r\n is one break
    jmp .bsl_break_have
.bsl_break_lf:
    lea rax, [r15 + 1]
    jmp .bsl_break_have
.bsl_at_end:
    mov rax, r15                ; no break: the line runs to the end
.bsl_break_have:
    mov [rbp - BSL_NEXT], rax

    ; The line stops at r15 without its break, at rax with it.
    mov rsi, r15
    cmp qword [rbp - BSL_KEEP], 0
    je .bsl_have_stop
    mov rsi, rax
.bsl_have_stop:
    sub rsi, r13
    lea rdi, [rbx + r13]
    call bytes_from_data
    test rax, rax
    jz .bsl_oom_list
    mov r15, rax
    mov rdi, r14
    mov rsi, rax
    call list_append            ; takes its own reference -- err: a list built here is not being sorted
    mov rdi, r15
    call obj_decref
    mov r13, [rbp - BSL_NEXT]
    jmp .bsl_loop

.bsl_done:
    mov rax, r14
    mov edx, TAG_PTR
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.bsl_type:
    SET_EXC exc_TypeError_type, "a bytes-like object is required"
    jmp .bsl_fail
.bsl_args:
    SET_EXC exc_TypeError_type, "splitlines() takes at most 1 argument"
    jmp .bsl_fail
.bsl_oom_list:
    mov rdi, r14                ; the lines so far
    call obj_decref
.bsl_oom:
    SET_EXC exc_MemoryError_type, "out of memory"
.bsl_fail:
    xor eax, eax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC bytes_method_splitlines


;; ============================================================================
;; bytes_method_translate(args, nargs) -> a new bytes
;;   translate(table, delete=b'')
;;
;; table is None or a 256-byte mapping; delete names bytes to drop, and is
;; applied before the mapping, as CPython's is.  This is the method
;; re._compiler reaches for -- _mk_bitmap ends in bits.translate(_BITS_TRANS)
;; -- so a bytearray without it cannot compile a character class.
;; Fails: 0
;; ============================================================================
BTR_ARGS  equ 8
BTR_DATA  equ 16
BTR_LEN   equ 24
BTR_TABLE equ 32
BTR_DEL   equ 40
BTR_DLEN  equ 48
BTR_OBJ   equ 56
BTR_FRAME equ 64            ; + 0 pushes = 64

DEF_FUNC bytes_method_translate, BTR_FRAME
    cmp rsi, 2
    jl .btr_args
    cmp rsi, 3
    jg .btr_args
    mov [rbp - BTR_DEL], rsi    ; nargs, until the delete set displaces it
    BS_SUBJECT BTR_ARGS, BTR_DATA, BTR_LEN, .btr_type

    ; The table: None leaves every byte alone.
    mov qword [rbp - BTR_TABLE], 0
    mov rdi, [rbp - BTR_ARGS]
    mov rdi, [rdi + 8]
    lea rcx, [rel none_singleton]   ; a borrowed compare: LOAD_NONE increfs
    cmp rdi, rcx
    je .btr_have_table
    mov [rbp - BTR_TABLE], rdi      ; the object, for the refusal below
    call bytes_like_ptr_len
    test ecx, ecx
    jz .btr_table_type
    cmp r10, 256
    jne .btr_table_len
    mov [rbp - BTR_TABLE], rax
.btr_have_table:

    mov rcx, [rbp - BTR_DEL]
    mov qword [rbp - BTR_DEL], 0
    mov qword [rbp - BTR_DLEN], 0
    cmp rcx, 3
    jl .btr_have_del
    mov rdi, [rbp - BTR_ARGS]
    mov rdi, [rdi + 16]
    lea rcx, [rel none_singleton]
    cmp rdi, rcx
    je .btr_have_del
    call bytes_like_ptr_len
    test ecx, ecx
    jz .btr_del_type
    mov [rbp - BTR_DEL], rax
    mov [rbp - BTR_DLEN], r10
.btr_have_del:

    ; The result is at most the subject's length; it is trimmed below.
    mov rdi, [rbp - BTR_LEN]
    call bytes_new
    test rax, rax
    jz .btr_oom
    mov [rbp - BTR_OBJ], rax

    mov r8, [rbp - BTR_DATA]
    mov r9, [rbp - BTR_LEN]
    lea rdi, [rax + PyBytesObject.data]
    mov r10, [rbp - BTR_TABLE]
    xor r11d, r11d              ; index into the subject
    xor eax, eax                ; index into the output
.btr_loop:
    cmp r11, r9
    jge .btr_done
    movzx ecx, byte [r8 + r11]

    ; Deleted?  A linear scan: the delete set is short in every real use, and
    ; a 256-bit map would cost more to build than it saves.
    mov rdx, [rbp - BTR_DEL]
    test rdx, rdx
    jz .btr_keep
    mov rsi, [rbp - BTR_DLEN]
.btr_del_scan:
    test rsi, rsi
    jz .btr_keep
    dec rsi
    cmp cl, [rdx + rsi]
    jne .btr_del_scan
    jmp .btr_next               ; dropped
.btr_keep:
    test r10, r10
    jz .btr_store
    movzx ecx, byte [r10 + rcx]
.btr_store:
    mov [rdi + rax], cl
    inc rax
.btr_next:
    inc r11
    jmp .btr_loop

.btr_done:
    ; Deletions leave the object longer than its contents.  Shortening
    ; ob_size in place is safe: the allocation is unchanged and the NUL moves
    ; down into it.
    mov rdx, [rbp - BTR_OBJ]
    mov [rdx + PyBytesObject.ob_size], rax
    mov byte [rdx + PyBytesObject.data + rax], 0
    mov rax, rdx
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret

.btr_type:
    SET_EXC exc_TypeError_type, "a bytes-like object is required"
    xor eax, eax
    leave
    ret
.btr_table_type:
    ; The type it actually got: this named 'str' whatever was passed.
    mov rsi, [rbp - BTR_TABLE]
    CSTRING rdi, `a bytes-like object is required, not '\x01'`
    extern set_type_error_with_name
    call set_type_error_with_name
    xor eax, eax
    leave
    ret
.btr_table_len:
    SET_EXC exc_ValueError_type, "translation table must be 256 characters long"
    xor eax, eax
    leave
    ret
.btr_del_type:
    SET_EXC exc_TypeError_type, "a bytes-like object is required"
    xor eax, eax
    leave
    ret
.btr_args:
    SET_EXC exc_TypeError_type, "translate() takes at least 1 argument"
    xor eax, eax
    leave
    ret
.btr_oom:
    SET_EXC exc_MemoryError_type, "out of memory"
    xor eax, eax
    leave
    ret
END_FUNC bytes_method_translate


;; ============================================================================
;; bytes_staticmethod_maketrans(args, nargs) -> a 256-byte bytes
;;
;; A staticmethod, so args[0] is the first argument and not a type.  Both
;; types answer with a bytes, bytearray included -- CPython's does too.
;; Fails: 0
;; ============================================================================
BMT_FROM  equ 8
BMT_FLEN  equ 16
BMT_TO    equ 24
BMT_OBJ   equ 32
BMT_NARGS equ 40            ; the count, for the arity refusal
BMT_FRAME equ 48            ; + 0 pushes = 48

DEF_FUNC bytes_staticmethod_maketrans, BMT_FRAME
    mov [rbp - BMT_NARGS], rsi
    cmp rsi, 2
    jne .bmt_args
    mov r8, rdi

    mov rdi, [r8]
    push r8
    sub rsp, 8
    call bytes_like_ptr_len
    add rsp, 8
    pop r8
    test ecx, ecx
    jz .bmt_type
    mov [rbp - BMT_FROM], rax
    mov [rbp - BMT_FLEN], r10

    mov rdi, [r8 + 8]
    call bytes_like_ptr_len
    test ecx, ecx
    jz .bmt_type
    cmp r10, [rbp - BMT_FLEN]
    jne .bmt_len
    mov [rbp - BMT_TO], rax

    mov edi, 256
    call bytes_new
    test rax, rax
    jz .bmt_oom
    mov [rbp - BMT_OBJ], rax

    ; Identity first, then the pairs on top of it.
    lea r8, [rax + PyBytesObject.data]
    xor ecx, ecx
.bmt_identity:
    mov [r8 + rcx], cl
    inc ecx
    cmp ecx, 256
    jb .bmt_identity

    mov r9, [rbp - BMT_FROM]
    mov r10, [rbp - BMT_TO]
    mov r11, [rbp - BMT_FLEN]
    xor ecx, ecx
.bmt_pairs:
    cmp rcx, r11
    jge .bmt_done
    movzx eax, byte [r9 + rcx]
    movzx edx, byte [r10 + rcx]
    mov [r8 + rax], dl
    inc rcx
    jmp .bmt_pairs

.bmt_done:
    mov rax, [rbp - BMT_OBJ]
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret

.bmt_type:
    SET_EXC exc_TypeError_type, "a bytes-like object is required"
    xor eax, eax
    leave
    ret
.bmt_len:
    SET_EXC exc_ValueError_type, "maketrans arguments must have same length"
    xor eax, eax
    leave
    ret
.bmt_args:
    mov rsi, [rbp - BMT_NARGS]
    CSTRING rdi, "maketrans expected 2 arguments, got "
    xor edx, edx
    extern set_type_error_counted
    call set_type_error_counted
    xor eax, eax
    leave
    ret
.bmt_oom:
    SET_EXC exc_MemoryError_type, "out of memory"
    xor eax, eax
    leave
    ret
END_FUNC bytes_staticmethod_maketrans


;; ============================================================================
;; bytes_affix_impl(rdi = args, rsi = nargs, edx = 1 suffix / 0 prefix)
;;   -> a new bytes, shortened when the affix is there
;;
;; removeprefix and removesuffix.  Both always answer with a new object, even
;; when nothing was removed: CPython's may return self for a bytes, but a
;; bytearray must not alias, and one shape for both is worth the copy.
;; Fails: 0
;; ============================================================================
BRA_ARGS  equ 8
BRA_DATA  equ 16
BRA_LEN   equ 24
BRA_MODE  equ 32
BRA_AFFIX equ 40            ; the affix object, for the refusal
BRA_FRAME equ 48            ; + 0 pushes = 48

DEF_FUNC bytes_affix_impl, BRA_FRAME
    mov [rbp - BRA_MODE], rdx
    cmp rsi, 2
    jne .bra_args
    BS_SUBJECT BRA_ARGS, BRA_DATA, BRA_LEN, .bra_type

    mov rdi, [rbp - BRA_ARGS]
    mov rdi, [rdi + 8]
    mov [rbp - BRA_AFFIX], rdi      ; the object, for the refusal below
    call bytes_like_ptr_len
    test ecx, ecx
    jz .bra_affix_type

    ; rax = the affix, r10 = its length
    mov r8, [rbp - BRA_DATA]
    mov r9, [rbp - BRA_LEN]
    test r10, r10
    jz .bra_whole               ; an empty affix removes nothing
    cmp r10, r9
    ja .bra_whole

    xor ecx, ecx
    mov rdx, r8
    cmp qword [rbp - BRA_MODE], 0
    je .bra_cmp
    add rdx, r9
    sub rdx, r10                ; the suffix starts here
.bra_cmp:
    cmp rcx, r10
    jge .bra_matched
    movzx esi, byte [rdx + rcx]
    cmp sil, [rax + rcx]
    jne .bra_whole
    inc rcx
    jmp .bra_cmp

.bra_matched:
    mov rsi, r9
    sub rsi, r10
    mov rdi, r8
    cmp qword [rbp - BRA_MODE], 0
    jne .bra_build              ; a suffix: the same start, fewer bytes
    add rdi, r10                ; a prefix: start past it
.bra_build:
    call bytes_from_data
    test rax, rax
    jz .bra_oom
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret

.bra_whole:
    mov rdi, r8
    mov rsi, r9
    call bytes_from_data
    test rax, rax
    jz .bra_oom
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret

.bra_type:
    SET_EXC exc_TypeError_type, "a bytes-like object is required"
    xor eax, eax
    leave
    ret
.bra_affix_type:
    mov rsi, [rbp - BRA_AFFIX]
    CSTRING rdi, `a bytes-like object is required, not '\x01'`
    extern set_type_error_with_name
    call set_type_error_with_name
    xor eax, eax
    leave
    ret
.bra_args:
    SET_EXC exc_TypeError_type, "takes exactly one argument"
    xor eax, eax
    leave
    ret
.bra_oom:
    SET_EXC exc_MemoryError_type, "out of memory"
    xor eax, eax
    leave
    ret
END_FUNC bytes_affix_impl

DEF_FUNC_BARE bytes_method_removeprefix
    xor edx, edx
    jmp bytes_affix_impl
END_FUNC bytes_method_removeprefix

DEF_FUNC_BARE bytes_method_removesuffix
    mov edx, 1
    jmp bytes_affix_impl
END_FUNC bytes_method_removesuffix
