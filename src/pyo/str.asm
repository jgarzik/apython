; str_obj.asm - String type
; Phase 8: full string operations

%include "macros.inc"
%include "object.inc"
%include "types.inc"

extern ap_malloc
extern ap_free
extern ap_strlen
extern ap_memcpy
extern ap_strcmp
extern bool_true
extern bool_false
extern int_from_i64
extern int_to_i64
extern fatal_error
extern raise_exception
extern exc_IndexError_type
extern exc_TypeError_type
extern slice_type
extern slice_indices
extern type_type
extern obj_dealloc

; str_from_cstr_heap(const char *cstr) -> (rax=PyStrObject*, edx=TAG_PTR)
; Always heap-allocates. For struct fields that need a real pointer.
DEF_FUNC str_from_cstr_heap
    push rbx
    push r12

    mov rbx, rdi            ; save cstr

    ; Get string length
    call ap_strlen
    mov r12, rax             ; r12 = length

    ; Allocate: PyStrObject header + length + 8 (null + padding for 8-byte strcmp)
    lea rdi, [rax + PyStrObject.data + 8]
    call ap_malloc
    ; rax = new PyStrObject*

    ; Fill header
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel str_type]
    mov [rax + PyObject.ob_type], rcx
    mov [rax + PyStrObject.ob_size], r12
    mov qword [rax + PyStrObject.ob_hash], -1  ; not computed

    ; Copy string data
    push rax                 ; save obj ptr
    lea rdi, [rax + PyStrObject.data]
    mov rsi, rbx             ; source = cstr
    lea rdx, [r12 + 1]      ; length + null
    call ap_memcpy
    pop rax                  ; restore obj ptr

    ; Zero-fill 8 bytes at NUL terminator for ap_strcmp 8-byte reads
    mov qword [rax + PyStrObject.data + r12], 0

    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret
END_FUNC str_from_cstr_heap

; str_from_cstr(const char *cstr) -> (rax=payload, edx=tag)
; Creates a string from a C string. Always returns heap TAG_PTR.
DEF_FUNC_BARE str_from_cstr
    jmp str_from_cstr_heap
END_FUNC str_from_cstr

; str_new_heap(const char *data, int64_t len) -> (rax=PyStrObject*, edx=TAG_PTR)
; Always heap-allocates. For struct fields and internal use.
DEF_FUNC str_new_heap
    push rbx
    push r12
    push r13

    mov rbx, rdi            ; save data ptr
    mov r12, rsi            ; save length

    ; Allocate: header + length + 8 (null + padding for 8-byte strcmp)
    lea rdi, [r12 + PyStrObject.data + 8]
    call ap_malloc
    mov r13, rax             ; r13 = new PyStrObject*

    ; Fill header
    mov qword [r13 + PyObject.ob_refcnt], 1
    lea rcx, [rel str_type]
    mov [r13 + PyObject.ob_type], rcx
    mov [r13 + PyStrObject.ob_size], r12
    mov qword [r13 + PyStrObject.ob_hash], -1

    ; Copy data
    lea rdi, [r13 + PyStrObject.data]
    mov rsi, rbx
    mov rdx, r12
    call ap_memcpy

    ; Zero-fill 8 bytes at NUL position for ap_strcmp 8-byte reads
    mov qword [r13 + PyStrObject.data + r12], 0

    mov rax, r13
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC str_new_heap

; str_new(const char *data, int64_t len) -> (rax=payload, edx=tag)
; Creates a string from data with given length. Always returns heap TAG_PTR.
DEF_FUNC_BARE str_new
    jmp str_new_heap         ; tail-call heap path
END_FUNC str_new

; str_dealloc(PyObject *self)
DEF_FUNC_BARE str_dealloc
    ; String data is inline, just free the object
    jmp ap_free
END_FUNC str_dealloc

;; ============================================================================
;; str_repr(PyObject *self) -> PyObject*
;; Returns string with surrounding single quotes: 'hello'
;; ============================================================================
DEF_FUNC str_repr
    push rbx
    push r12
    push r13

    mov rbx, rdi            ; rbx = self
    mov r12, [rbx + PyStrObject.ob_size]  ; r12 = src length

    ; Allocate worst case: header + 2 quotes + 2*length + 8 (NUL padding)
    lea rdi, [r12*2 + PyStrObject.data + 10]
    call ap_malloc
    mov r13, rax             ; r13 = new str

    ; Fill header
    mov qword [r13 + PyObject.ob_refcnt], 1
    lea rcx, [rel str_type]
    mov [r13 + PyObject.ob_type], rcx
    mov qword [r13 + PyStrObject.ob_hash], -1

    ; Write opening quote
    mov byte [r13 + PyStrObject.data], "'"

    ; Copy with escaping: rsi=src, rdi=dst, rcx=src index
    lea rsi, [rbx + PyStrObject.data]
    lea rdi, [r13 + PyStrObject.data + 1]
    xor ecx, ecx

.sr_loop:
    cmp rcx, r12
    jge .sr_done
    movzx eax, byte [rsi + rcx]

    cmp al, 10               ; newline
    je .sr_esc_n
    cmp al, 13               ; carriage return
    je .sr_esc_r
    cmp al, 9                ; tab
    je .sr_esc_t
    cmp al, 0x5C             ; backslash
    je .sr_esc_bs
    cmp al, 0x27             ; single quote
    je .sr_esc_sq

    ; Normal character
    mov [rdi], al
    inc rdi
    inc rcx
    jmp .sr_loop

.sr_esc_n:
    mov byte [rdi], 0x5C     ; backslash
    mov byte [rdi + 1], 'n'
    add rdi, 2
    inc rcx
    jmp .sr_loop

.sr_esc_r:
    mov byte [rdi], 0x5C
    mov byte [rdi + 1], 'r'
    add rdi, 2
    inc rcx
    jmp .sr_loop

.sr_esc_t:
    mov byte [rdi], 0x5C
    mov byte [rdi + 1], 't'
    add rdi, 2
    inc rcx
    jmp .sr_loop

.sr_esc_bs:
    mov byte [rdi], 0x5C
    mov byte [rdi + 1], 0x5C
    add rdi, 2
    inc rcx
    jmp .sr_loop

.sr_esc_sq:
    mov byte [rdi], 0x5C
    mov byte [rdi + 1], 0x27
    add rdi, 2
    inc rcx
    jmp .sr_loop

.sr_done:
    ; Write closing quote and null
    mov byte [rdi], "'"
    mov qword [rdi + 1], 0  ; 8-byte zero-fill for ap_strcmp

    ; Calculate actual ob_size: (rdi - data_start) + 1 for closing quote
    lea rax, [r13 + PyStrObject.data]
    sub rdi, rax               ; rdi = chars written including open quote
    inc rdi                    ; + closing quote
    mov [r13 + PyStrObject.ob_size], rdi

    mov rax, r13
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC str_repr

;; ============================================================================
;; str_str(PyObject *self) -> PyObject*
;; tp_str: returns self with INCREF (no quotes)
;; ============================================================================
DEF_FUNC_BARE str_str
    inc qword [rdi + PyObject.ob_refcnt]
    mov rax, rdi
    ret
END_FUNC str_str

;; ============================================================================
;; str_hash(PyObject *self) -> int64
;; FNV-1a hash
;; ============================================================================
DEF_FUNC str_hash

    ; Check cached hash
    mov rax, [rdi + PyStrObject.ob_hash]
    cmp rax, -1
    jne .done

    ; Compute FNV-1a
    mov rcx, [rdi + PyStrObject.ob_size]
    lea rsi, [rdi + PyStrObject.data]
    mov rax, 0xcbf29ce484222325     ; FNV offset basis
    mov rdx, 0x100000001b3          ; FNV prime
    ; 4x unrolled FNV-1a loop
align 16
.loop4:
    cmp rcx, 4
    jb .tail
    movzx r8d, byte [rsi]
    xor rax, r8
    imul rax, rdx
    movzx r8d, byte [rsi+1]
    xor rax, r8
    imul rax, rdx
    movzx r8d, byte [rsi+2]
    xor rax, r8
    imul rax, rdx
    movzx r8d, byte [rsi+3]
    xor rax, r8
    imul rax, rdx
    add rsi, 4
    sub rcx, 4
    jmp .loop4
.tail:
    test rcx, rcx
    jz .store
    movzx r8d, byte [rsi]
    xor rax, r8
    imul rax, rdx
    inc rsi
    dec rcx
    jmp .tail
.store:
    ; Ensure hash is never -1
    cmp rax, -1
    jne .cache
    mov rax, -2
.cache:
    mov [rdi + PyStrObject.ob_hash], rax
.done:
    leave
    ret
END_FUNC str_hash

;; ============================================================================
;; str_concat(PyObject *a, PyObject *b, ?, ecx=right_tag) -> (rax,edx) fat value
;; String concatenation via nb_add.
;; Binary op handler passes right_tag in ecx. Direct callers must set ecx=TAG_PTR.
;; ============================================================================
DEF_FUNC str_concat
    ; Check right tag first — non-TAG_PTR means not a heap string
    cmp ecx, TAG_PTR
    jne .concat_type_error
    ; Verify right operand is a string (ob_type == str_type)
    mov rax, [rsi + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rax, rdx
    jne .concat_type_error

    push rbx
    push r12
    push r13

    mov rbx, rdi            ; a
    mov r12, rsi            ; b

    ; Get lengths
    mov r13, [rbx + PyStrObject.ob_size]   ; len_a
    add r13, [r12 + PyStrObject.ob_size]   ; total length

    ; Allocate new string (+ 8 for NUL padding for 8-byte strcmp)
    lea rdi, [r13 + PyStrObject.data + 8]
    call ap_malloc
    push rax                ; save new str

    ; Fill header
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel str_type]
    mov [rax + PyObject.ob_type], rcx
    mov [rax + PyStrObject.ob_size], r13
    mov qword [rax + PyStrObject.ob_hash], -1

    ; Copy first string
    lea rdi, [rax + PyStrObject.data]
    lea rsi, [rbx + PyStrObject.data]
    mov rdx, [rbx + PyStrObject.ob_size]
    call ap_memcpy

    ; Copy second string
    mov rax, [rsp]          ; reload new str
    mov rcx, [rbx + PyStrObject.ob_size]
    lea rdi, [rax + PyStrObject.data + rcx]
    lea rsi, [r12 + PyStrObject.data]
    mov rdx, [r12 + PyStrObject.ob_size]
    call ap_memcpy

    ; Zero-fill 8 bytes at NUL position for ap_strcmp
    pop rax
    mov qword [rax + PyStrObject.data + r13], 0

    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret

.concat_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "can only concatenate str (not other type) to str"
    call raise_exception
END_FUNC str_concat

;; ============================================================================
;; str_repeat(PyObject *str_obj, PyObject *int_obj) -> PyObject*
;; String repetition via nb_multiply
;; ============================================================================
DEF_FUNC str_repeat
    push rbx
    push r12
    push r13
    push r14

    mov rbx, rdi            ; str
    mov rdi, rsi            ; int (count payload)
    mov edx, ecx            ; count tag (right operand)
    call int_to_i64
    mov r12, rax             ; r12 = repeat count

    ; Clamp negative to 0
    test r12, r12
    jg .positive
    xor r12d, r12d
.positive:

    mov r13, [rbx + PyStrObject.ob_size]   ; r13 = str length
    imul r14, r13, 1                        ; r14 = str length (copy)
    imul r14, r12                           ; r14 = total length

    ; Allocate new string (+ 8 for NUL padding for 8-byte strcmp)
    lea rdi, [r14 + PyStrObject.data + 8]
    call ap_malloc
    push rax                ; save

    ; Fill header
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel str_type]
    mov [rax + PyObject.ob_type], rcx
    mov [rax + PyStrObject.ob_size], r14
    mov qword [rax + PyStrObject.ob_hash], -1

    ; Copy str r12 times
    lea rdi, [rax + PyStrObject.data]
    xor ecx, ecx            ; ecx = iteration counter
.repeat_loop:
    cmp rcx, r12
    jge .repeat_done
    push rcx
    push rdi
    lea rsi, [rbx + PyStrObject.data]
    mov rdx, r13
    call ap_memcpy
    pop rdi
    pop rcx
    add rdi, r13
    inc rcx
    jmp .repeat_loop

.repeat_done:
    ; Zero-fill 8 bytes at NUL position for ap_strcmp
    pop rax
    mov qword [rax + PyStrObject.data + r14], 0
    mov edx, TAG_PTR

    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC str_repeat

;; ============================================================================
;; str_mod(PyStrObject *fmt, PyObject *args) -> PyStrObject*
;; nb_remainder: implements "fmt % args" string formatting
;; Handles: %s, %d, %i, %r, %f, %%
;; args can be a single value or a tuple
;; ============================================================================
extern obj_str
extern obj_repr
extern tuple_type
extern obj_decref

; str_mod stack offsets
SM_FMT     equ 8
SM_ARGS    equ 16
SM_BUF     equ 24
SM_CAP     equ 32
SM_ISTUPLE equ 40
SM_NARGS   equ 48
SM_ATAG    equ 56
SM_FRAME   equ 56

DEF_FUNC str_mod, SM_FRAME
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
    mov qword [rbp-SM_NARGS], 1   ; nargs = 1 (single value)
    cmp ecx, TAG_PTR
    jne .sm_not_tuple           ; non-heap → single value (SmallInt/Float/Bool/None)
    mov rax, [rsi + PyObject.ob_type]
    lea rcx, [rel tuple_type]
    cmp rax, rcx
    jne .sm_not_tuple
    mov qword [rbp-SM_ISTUPLE], 1  ; is_tuple = true
    mov rax, [rsi + PyTupleObject.ob_size]
    mov [rbp-SM_NARGS], rax    ; nargs = tuple size
.sm_not_tuple:

    ; Allocate initial heap buffer (8192 bytes)
    extern ap_malloc, ap_free, ap_realloc
    mov edi, 8192
    call ap_malloc
    mov r13, rax               ; r13 = output buffer
    mov [rbp-SM_BUF], rax
    mov qword [rbp-SM_CAP], 8192
    xor r14d, r14d             ; r14 = output pos
    xor r15d, r15d             ; r15 = arg index

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
    cmp al, '0'
    jb .sm_dispatch
    cmp al, '9'
    ja .sm_dispatch
    inc rcx
    cmp rcx, r12
    jge .sm_done
    jmp .sm_skip_prec

.sm_dispatch:
    movzx eax, byte [rbx + rcx]
    inc rcx                    ; consume conversion char

    cmp al, '%'
    je .sm_percent
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
    ; Unknown: just output the char
    mov byte [r13 + r14], '%'
    inc r14
    mov [r13 + r14], al
    inc r14
    jmp .sm_loop

.sm_percent:
    mov byte [r13 + r14], '%'
    inc r14
    jmp .sm_loop

.sm_str:
    ; Get next arg
    push rcx
    call .sm_get_arg
    ; rax = arg payload, rdx = arg tag
    mov rdi, rax
    mov rsi, rdx               ; tag for obj_str
    call obj_str
    ; rax = str result
    jmp .sm_copy_str

.sm_int:
    push rcx
    call .sm_get_arg
    ; If TAG_BOOL, convert to TAG_SMALLINT so we get "0"/"1" not "False"/"True"
    cmp edx, TAG_BOOL
    je .sm_int_from_bool
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
    call obj_str               ; int.__str__ = int_repr
    jmp .sm_copy_str

.sm_repr:
    push rcx
    call .sm_get_arg
    mov rdi, rax
    mov rsi, rdx               ; tag for obj_repr (64-bit)
    call obj_repr
    jmp .sm_copy_str

.sm_hex:
    ; %x: format integer as lowercase hex
    push rcx
    call .sm_get_arg
    ; Convert TAG_BOOL to TAG_SMALLINT
    cmp edx, TAG_BOOL
    je .sm_hex_from_bool
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
    mov rax, 1
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
    and edx, 0xF
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
    cmp qword [rbp-SM_ISTUPLE], 1
    je .sm_arg_tuple
    ; Single value
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
    mov r8, [rax + PyTupleObject.ob_item_tags]   ; tags
    mov rax, [rcx + rdx*8]                       ; arg payload
    movzx edx, byte [r8 + rdx]                   ; arg tag from tuple
    inc r15
    ret
.sm_arg_none:
    xor eax, eax              ; payload = 0
    mov edx, TAG_NONE         ; tag = TAG_NONE
    inc r15
    ret

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
    call ap_realloc
    mov r13, rax
    mov [rbp-SM_BUF], rax
.sm_cap_ok:
    ret

.sm_done:
    ; Null-terminate and create string
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
END_FUNC str_mod

;; ============================================================================
;; str_compare(left, right, op, left_tag, right_tag) -> (rax,edx) fat bool
;; Rich comparison for strings. Both operands are heap PyStrObject*.
;; Caller convention: rdi=left, rsi=right, edx=op, rcx=left_tag, r8=right_tag
;; Note: r8 may be unset by callers like max/min (rsi is always a valid heap
;; string in that case, so the TAG_RC_BIT guard is conservative-safe).
;; ============================================================================

DEF_FUNC str_compare
    push rbx

    mov ebx, edx            ; save op

    ; --- Resolve right operand to a data pointer (-> rsi) ---
    ; Non-string guard: TAG_RC_BIT (bit 8) is set only for TAG_PTR (0x105).
    ; Non-pointer tags (0-4) and unset r8 from max/min: if TAG_RC_BIT clear
    ; → not a string.
    test r8d, TAG_RC_BIT
    jz .not_string
    ; Heap pointer — verify ob_type == str_type
    mov rax, [rsi + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rax, rdx
    jne .not_string
    lea rsi, [rsi + PyStrObject.data]

    ; --- Resolve left operand to a data pointer (-> rdi) ---
    ; Heap str — no type check needed (caller dispatched via str_type)
    lea rdi, [rdi + PyStrObject.data]

    ; --- Compare the two null-terminated data pointers ---
    call ap_strcmp
    ; eax = strcmp result

    ; Dispatch on comparison op (ebx)
    cmp ebx, PY_NE
    je .do_ne
    cmp ebx, PY_EQ
    je .do_eq
    cmp ebx, PY_LT
    je .do_lt
    cmp ebx, PY_GT
    je .do_gt
    cmp ebx, PY_LE
    je .do_le
    ; fall through: PY_GE
    test eax, eax
    jge .ret_true
    jmp .ret_false
.do_lt:
    test eax, eax
    js .ret_true
    jmp .ret_false
.do_le:
    test eax, eax
    jle .ret_true
    jmp .ret_false
.do_eq:
    test eax, eax
    jz .ret_true
    jmp .ret_false
.do_ne:
    test eax, eax
    jnz .ret_true
    jmp .ret_false
.do_gt:
    test eax, eax
    jg .ret_true
    jmp .ret_false

.not_string:
    ; Right operand is not a string.
    ; EQ → False, NE → True, ordering → NotImplemented (NULL)
    cmp ebx, PY_EQ
    je .ret_false
    cmp ebx, PY_NE
    je .ret_true
    ; Ordering comparison with non-string → return NotImplemented (NULL)
    RET_NULL
    pop rbx
    leave
    ret

.ret_true:
    lea rax, [rel bool_true]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    pop rbx
    leave
    ret
.ret_false:
    lea rax, [rel bool_false]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    pop rbx
    leave
    ret
END_FUNC str_compare

;; ============================================================================
;; str_len(PyObject *self) -> int64_t
;; sq_length: returns ob_size
;; ============================================================================
DEF_FUNC_BARE str_len
    mov rax, [rdi + PyStrObject.ob_size]
    ret
END_FUNC str_len

;; ============================================================================
;; str_getitem(PyObject *self, int64_t index) -> PyObject*
;; sq_item: return single-char string at index
;; ============================================================================
DEF_FUNC str_getitem
    push rbx
    push r12

    mov rbx, rdi            ; self
    mov r12, rsi            ; index

    ; Handle negative index
    test r12, r12
    jns .positive
    add r12, [rbx + PyStrObject.ob_size]
.positive:

    ; Bounds check
    cmp r12, [rbx + PyStrObject.ob_size]
    jge .index_error
    cmp r12, 0
    jl .index_error

    ; Create single-char string
    lea rdi, [rbx + PyStrObject.data]
    add rdi, r12
    mov rsi, 1
    call str_new

    pop r12
    pop rbx
    leave
    ret

.index_error:
    lea rdi, [rel exc_IndexError_type]
    CSTRING rsi, "string index out of range"
    call raise_exception
END_FUNC str_getitem

;; ============================================================================
;; str_subscript(PyObject *self, PyObject *key) -> PyObject*
;; mp_subscript: index with int or slice key (for BINARY_SUBSCR)
;; ============================================================================
DEF_FUNC str_subscript
    push rbx

    mov rbx, rdi            ; save self

    ; Check if key is a SmallInt (edx = key tag from caller)
    cmp edx, TAG_SMALLINT
    je .ss_int               ; SmallInt -> int path
    mov rax, [rsi + PyObject.ob_type]
    lea rcx, [rel slice_type]
    cmp rax, rcx
    je .ss_slice

.ss_int:
    ; Convert key to i64
    mov rdi, rsi
    call int_to_i64
    mov rsi, rax

    ; Call str_getitem
    mov rdi, rbx
    call str_getitem

    pop rbx
    leave
    ret

.ss_slice:
    mov rdi, rbx
    ; rsi = slice
    call str_getslice
    pop rbx
    leave
    ret
END_FUNC str_subscript

;; ============================================================================
;; str_contains(PyObject *self, PyObject *substr, int substr_tag) -> int (0/1)
;; sq_contains: check if substr is in self using strstr
;; ============================================================================
DEF_FUNC str_contains

    ; Validate substr is a string (TAG_PTR with ob_type == str_type)
    cmp edx, TAG_PTR
    jne .str_contains_type_error
    mov rax, [rsi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    jne .str_contains_type_error

    extern ap_strstr
    lea rdi, [rdi + PyStrObject.data]
    lea rsi, [rsi + PyStrObject.data]
    call ap_strstr
    test rax, rax
    setnz al
    movzx eax, al

    leave
    ret

.str_contains_type_error:
    extern exc_TypeError_type
    extern raise_exception
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "'in <string>' requires string as left operand"
    call raise_exception
END_FUNC str_contains

;; ============================================================================
;; str_bool(PyObject *self) -> int (0/1)
;; nb_bool: true if len > 0
;; ============================================================================
DEF_FUNC_BARE str_bool
    cmp qword [rdi + PyStrObject.ob_size], 0
    setne al
    movzx eax, al
    ret
END_FUNC str_bool

;; ============================================================================
;; str_getslice(PyStrObject *str, PySliceObject *slice) -> PyStrObject*
;; Creates a new string from a slice of the original.
;; ============================================================================
DEF_FUNC str_getslice
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8                 ; align

    mov rbx, rdi               ; str
    mov r12, rsi               ; slice

    ; Get slice indices
    mov rdi, r12
    mov rsi, [rbx + PyStrObject.ob_size]
    call slice_indices
    mov r13, rax               ; start
    mov r14, rdx               ; stop
    mov r15, rcx               ; step

    ; Compute slicelength
    test r15, r15
    jg .sgs_pos_step
    ; Negative step
    mov rax, r13
    sub rax, r14
    dec rax
    mov rcx, r15
    neg rcx
    xor edx, edx
    div rcx
    inc rax
    jmp .sgs_have_len

.sgs_pos_step:
    mov rax, r14
    sub rax, r13
    jle .sgs_empty
    dec rax
    xor edx, edx
    div r15
    inc rax
    jmp .sgs_have_len

.sgs_empty:
    xor eax, eax

.sgs_have_len:
    ; rax = slicelength
    push rax                   ; save slicelength

    ; For step=1, fast path: use str_new with contiguous data
    cmp r15, 1
    jne .sgs_general

    ; Fast path: contiguous slice (heap — merges with general heap path)
    lea rdi, [rbx + PyStrObject.data]
    add rdi, r13               ; data + start
    mov rsi, rax               ; length = slicelength
    call str_new_heap
    add rsp, 8                 ; discard slicelength
    jmp .sgs_ret

.sgs_general:
    ; General case: build char by char on stack buffer
    ; Allocate: header + slicelength + 1
    mov rdi, rax
    add rdi, PyStrObject.data + 8  ; +8 NUL padding for ap_strcmp
    call ap_malloc
    push rax                   ; save new str obj

    ; Fill header
    mov rcx, [rsp + 8]        ; slicelength
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rdx, [rel str_type]
    mov [rax + PyObject.ob_type], rdx
    mov [rax + PyStrObject.ob_size], rcx
    mov qword [rax + PyStrObject.ob_hash], -1

    ; Copy chars: for i=0..slicelength-1, dst[i] = src[start + i*step]
    xor ecx, ecx
.sgs_copy:
    cmp rcx, [rsp + 8]        ; slicelength
    jge .sgs_null_term
    mov rax, rcx
    imul rax, r15              ; i * step
    add rax, r13               ; start + i*step
    movzx edx, byte [rbx + PyStrObject.data + rax]
    mov rax, [rsp]             ; new str
    mov [rax + PyStrObject.data + rcx], dl
    inc rcx
    jmp .sgs_copy

.sgs_null_term:
    mov rax, [rsp]             ; new str
    mov rcx, [rsp + 8]        ; slicelength
    mov qword [rax + PyStrObject.data + rcx], 0  ; 8-byte zero-fill for ap_strcmp

    pop rax                    ; new str
    add rsp, 8                 ; discard slicelength

.sgs_ret:
    add rsp, 8                 ; undo alignment
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    mov edx, TAG_PTR
    leave
    ret
END_FUNC str_getslice

;; ============================================================================
;; String Iterator
;; ============================================================================

extern obj_decref
extern obj_incref
extern iter_self

;; str_tp_iter(PyStrObject *self) -> PyStrIterObject*
;; tp_iter for str type: create a new string iterator
;; ============================================================================
global str_tp_iter
DEF_FUNC str_tp_iter
    push rbx

    mov rbx, rdi               ; save str

    mov edi, PyStrIterObject_size
    call ap_malloc

    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel str_iter_type]
    mov [rax + PyObject.ob_type], rcx
    mov [rax + PyStrIterObject.it_seq], rbx
    mov qword [rax + PyStrIterObject.it_index], 0

    ; INCREF the string
    INCREF rbx

    pop rbx
    leave
    ret
END_FUNC str_tp_iter

;; str_iter_next(PyStrIterObject *self) -> PyObject* or NULL
;; Return next character as a 1-char string, or NULL if exhausted
;; ============================================================================
global str_iter_next
DEF_FUNC str_iter_next
    push rbx

    mov rbx, rdi                                      ; self (iter)
    mov rax, [rbx + PyStrIterObject.it_seq]            ; str
    mov rcx, [rbx + PyStrIterObject.it_index]          ; index

    ; Check bounds (byte index vs ob_size)
    cmp rcx, [rax + PyStrObject.ob_size]
    jge .si_exhausted

    ; Create single-char string from current byte position
    lea rdi, [rax + PyStrObject.data]
    add rdi, rcx
    mov rsi, 1
    call str_new

    ; Advance index - str_new already set rax/rdx correctly
    inc qword [rbx + PyStrIterObject.it_index]
    pop rbx
    leave
    ret

.si_exhausted:
    RET_NULL
    pop rbx
    leave
    ret
END_FUNC str_iter_next

;; str_iter_dealloc(PyObject *self)
;; ============================================================================
global str_iter_dealloc
DEF_FUNC str_iter_dealloc
    push rbx
    mov rbx, rdi

    ; DECREF the string
    mov rdi, [rbx + PyStrIterObject.it_seq]
    call obj_decref

    ; Free self
    mov rdi, rbx
    call ap_free

    pop rbx
    leave
    ret
END_FUNC str_iter_dealloc

;; ============================================================================
;; Data section
;; ============================================================================
section .data

str_name: db "str", 0

; String number methods (for + and * operators)
align 8
str_number_methods:
    dq str_concat           ; nb_add          +0
    dq 0                    ; nb_subtract     +8
    dq str_repeat           ; nb_multiply     +16
    dq str_mod              ; nb_remainder    +24
    dq 0                    ; nb_divmod       +32
    dq 0                    ; nb_power        +40
    dq 0                    ; nb_negative     +48
    dq 0                    ; nb_positive     +56
    dq 0                    ; nb_absolute     +64
    dq str_bool             ; nb_bool         +72
    dq 0                    ; nb_invert       +80
    dq 0                    ; nb_lshift       +88
    dq 0                    ; nb_rshift       +96
    dq 0                    ; nb_and          +104
    dq 0                    ; nb_xor          +112
    dq 0                    ; nb_or           +120
    dq 0                    ; nb_int          +128
    dq 0                    ; nb_float        +136
    dq 0                    ; nb_floor_divide +144
    dq 0                    ; nb_true_divide  +152
    dq 0                    ; nb_index        +160
    dq 0                        ; nb_iadd         +168
    dq 0                        ; nb_isub         +176
    dq 0                        ; nb_imul         +184
    dq 0                        ; nb_irem         +192
    dq 0                        ; nb_ipow         +200
    dq 0                        ; nb_ilshift      +208
    dq 0                        ; nb_irshift      +216
    dq 0                        ; nb_iand         +224
    dq 0                        ; nb_ixor         +232
    dq 0                        ; nb_ior          +240
    dq 0                        ; nb_ifloor_divide +248
    dq 0                        ; nb_itrue_divide +256

; String sequence methods
align 8
str_sequence_methods:
    dq str_len              ; sq_length       +0
    dq 0                    ; sq_concat       +8
    dq 0                    ; sq_repeat       +16
    dq str_getitem          ; sq_item         +24
    dq 0                    ; sq_ass_item     +32
    dq str_contains         ; sq_contains     +40
    dq 0                    ; sq_inplace_concat +48
    dq 0                    ; sq_inplace_repeat +56

; String mapping methods (for BINARY_SUBSCR with int key)
align 8
str_mapping_methods:
    dq str_len              ; mp_length       +0
    dq str_subscript         ; mp_subscript    +8
    dq 0                    ; mp_ass_subscript +16

; str type object
align 8
global str_type
str_type:
    dq 1                ; ob_refcnt
    dq type_type        ; ob_type
    dq str_name         ; tp_name
    dq PyStrObject.data ; tp_basicsize (minimum, without data)
    dq str_dealloc      ; tp_dealloc
    dq str_repr         ; tp_repr
    dq str_str          ; tp_str (returns self for strings, no quotes)
    dq str_hash         ; tp_hash
    dq 0                ; tp_call
    dq 0                ; tp_getattr
    dq 0                ; tp_setattr
    dq str_compare      ; tp_richcompare
    dq str_tp_iter      ; tp_iter
    dq 0                ; tp_iternext
    dq 0                ; tp_init
    dq 0                ; tp_new
    dq str_number_methods    ; tp_as_number
    dq str_sequence_methods  ; tp_as_sequence
    dq str_mapping_methods   ; tp_as_mapping
    dq 0                ; tp_base
    dq 0                ; tp_dict
    dq 0                ; tp_mro
    dq TYPE_FLAG_STR_SUBCLASS ; tp_flags
    dq 0                ; tp_bases
    dq 0                        ; tp_traverse
    dq 0                        ; tp_clear

; str_iter type data
align 8
str_iter_name: db "str_iterator", 0

align 8
str_iter_type:
    dq 1                        ; ob_refcnt
    dq type_type                ; ob_type
    dq str_iter_name            ; tp_name
    dq PyStrIterObject_size     ; tp_basicsize
    dq str_iter_dealloc         ; tp_dealloc
    dq 0                        ; tp_repr
    dq 0                        ; tp_str
    dq 0                        ; tp_hash
    dq 0                        ; tp_call
    dq 0                        ; tp_getattr
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq iter_self                ; tp_iter (return self)
    dq str_iter_next            ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq 0                        ; tp_as_number
    dq 0                        ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq 0                        ; tp_flags
    dq 0                        ; tp_bases
    dq 0                        ; tp_traverse
    dq 0                        ; tp_clear
