; methods.asm - Type methods for str, list, and dict
; Implements method functions and methods_init to populate tp_dict

%include "macros.inc"
%include "object.inc"
%include "types.inc"
%include "builtins.inc"


; External functions
extern ap_malloc
extern gc_alloc
extern gc_track
extern ap_free
extern ap_realloc
extern ap_memcpy
extern ap_memset
extern ap_memmove
extern ap_strcmp
extern ap_strlen
extern ap_strstr
extern ap_memcmp
extern obj_incref
extern obj_decref
extern obj_dealloc
extern obj_repr
extern obj_str
extern str_from_cstr_heap
extern str_new_heap
extern str_type
extern list_new
extern list_append
extern list_type
extern tuple_new
extern tuple_type
extern dict_new
extern dict_get
extern dict_set
extern dict_del
extern dict_type
extern none_singleton
extern bool_true
extern bool_false
extern int_from_i64
extern int_to_i64
extern builtin_func_new
extern raise_exception
extern fatal_error
extern exc_TypeError_type
extern exc_ValueError_type
extern exc_IndexError_type
extern exc_KeyError_type
extern int_type
extern set_type
extern object_type
extern object_new_fn
extern staticmethod_type
extern obj_is_true
extern list_sorting_error

; Set entry layout constants (must match set.asm)
SET_ENTRY_HASH    equ 0
SET_ENTRY_KEY     equ 8
SET_ENTRY_KEY_TAG equ 16
SET_ENTRY_SIZE    equ 24
extern set_add
extern set_contains
extern set_remove
extern set_new
extern set_tp_iter

;; ============================================================================
;; HELPER: add_method_to_dict(dict, name_cstr, func_ptr)
;; rdi=dict, rsi=name_cstr, rdx=func_ptr
;; Creates a builtin func wrapper and stores it in the dict.
;; ============================================================================
DEF_FUNC_LOCAL add_method_to_dict
    push rbx
    push r12
    push r13

    mov rbx, rdi            ; dict
    mov r12, rsi            ; name_cstr
    mov r13, rdx            ; func_ptr

    ; Create builtin func wrapper: builtin_func_new(func_ptr, name_cstr)
    mov rdi, r13
    mov rsi, r12
    call builtin_func_new
    push rax                ; save func obj

    ; Create key string from name
    mov rdi, r12
    call str_from_cstr_heap
    push rax                ; save key str

    ; dict_set(dict, key, func_obj)
    mov rdi, rbx
    mov rsi, rax            ; key
    mov rdx, [rsp + 8]     ; func obj
    mov ecx, TAG_PTR
    mov r8d, TAG_PTR
    call dict_set

    ; DECREF key (dict_set did INCREF)
    pop rdi
    call obj_decref

    ; DECREF func obj (dict_set did INCREF)
    pop rdi
    call obj_decref

    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC add_method_to_dict

;; ############################################################################
;;                         STRING METHODS
;; ############################################################################

;; ============================================================================
;; str_method_upper(args, nargs) -> new uppercase string
;; args[0] = self (PyStrObject*)
;; ============================================================================
DEF_FUNC str_method_upper
    push rbx
    push r12
    push r13

    mov rax, [rdi]          ; self = args[0]
    mov rbx, rax            ; rbx = self
    mov r12, [rbx + PyStrObject.ob_size]  ; r12 = length

    ; Create new string: str_new(data, len)
    lea rdi, [rbx + PyStrObject.data]
    mov rsi, r12
    call str_new_heap
    mov r13, rax            ; r13 = new string

    ; Convert each byte to uppercase in-place
    xor ecx, ecx
.upper_loop:
    cmp rcx, r12
    jge .upper_done
    movzx eax, byte [r13 + PyStrObject.data + rcx]
    cmp al, 'a'
    jb .upper_next
    cmp al, 'z'
    ja .upper_next
    sub al, 32             ; 'a'-'A' = 32
    mov [r13 + PyStrObject.data + rcx], al
.upper_next:
    inc rcx
    jmp .upper_loop
.upper_done:
    mov rax, r13
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC str_method_upper

;; ============================================================================
;; str_method_lower(args, nargs) -> new lowercase string
;; ============================================================================
DEF_FUNC str_method_lower
    push rbx
    push r12
    push r13

    mov rax, [rdi]          ; self
    mov rbx, rax
    mov r12, [rbx + PyStrObject.ob_size]

    lea rdi, [rbx + PyStrObject.data]
    mov rsi, r12
    call str_new_heap
    mov r13, rax

    xor ecx, ecx
.lower_loop:
    cmp rcx, r12
    jge .lower_done
    movzx eax, byte [r13 + PyStrObject.data + rcx]
    cmp al, 'A'
    jb .lower_next
    cmp al, 'Z'
    ja .lower_next
    add al, 32
    mov [r13 + PyStrObject.data + rcx], al
.lower_next:
    inc rcx
    jmp .lower_loop
.lower_done:
    mov rax, r13
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC str_method_lower

;; ============================================================================
;; str_method_strip(args, nargs) -> new stripped string
;; Strip whitespace (space, tab, newline, cr, form feed, vertical tab) from both ends
;; ============================================================================
DEF_FUNC str_method_strip
    push rbx
    push r12
    push r13
    push r14

    mov rax, [rdi]          ; self
    mov rbx, rax
    mov r12, [rbx + PyStrObject.ob_size]  ; length

    ; Find start (skip leading whitespace)
    xor r13d, r13d          ; r13 = start index
.strip_left:
    cmp r13, r12
    jge .strip_empty
    movzx eax, byte [rbx + PyStrObject.data + r13]
    cmp al, ' '
    je .strip_left_next
    cmp al, 9              ; tab
    je .strip_left_next
    cmp al, 10             ; newline
    je .strip_left_next
    cmp al, 13             ; carriage return
    je .strip_left_next
    cmp al, 11             ; vertical tab
    je .strip_left_next
    cmp al, 12             ; form feed
    je .strip_left_next
    jmp .strip_right_start
.strip_left_next:
    inc r13
    jmp .strip_left

.strip_empty:
    ; All whitespace - return empty string
    lea rdi, [rel empty_str_cstr]
    call str_from_cstr_heap
    jmp .strip_ret

.strip_right_start:
    ; Find end (skip trailing whitespace)
    mov r14, r12            ; r14 = end (exclusive)
.strip_right:
    cmp r14, r13
    jle .strip_empty
    movzx eax, byte [rbx + PyStrObject.data + r14 - 1]
    cmp al, ' '
    je .strip_right_next
    cmp al, 9
    je .strip_right_next
    cmp al, 10
    je .strip_right_next
    cmp al, 13
    je .strip_right_next
    cmp al, 11             ; vertical tab
    je .strip_right_next
    cmp al, 12             ; form feed
    je .strip_right_next
    jmp .strip_make
.strip_right_next:
    dec r14
    jmp .strip_right

.strip_make:
    ; Create new string from [start, end)
    lea rdi, [rbx + PyStrObject.data]
    add rdi, r13
    mov rsi, r14
    sub rsi, r13            ; length = end - start
    call str_new_heap

.strip_ret:
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC str_method_strip

;; ============================================================================
;; str_method_startswith(args, nargs) -> bool_true/bool_false
;; args[0]=self, args[1]=prefix
;; ============================================================================
DEF_FUNC str_method_startswith
    push rbx
    push r12
    push r13

    ; Validate args[1] is a string
    mov rax, [rdi + 24]        ; args[1] tag
    cmp eax, TAG_PTR
    jne .sw_type_error
    mov rax, [rdi + 16]
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    jne .sw_type_error

    mov rbx, [rdi]          ; self
    mov r12, [rdi + 16]     ; prefix (args[1])

    mov r13, [r12 + PyStrObject.ob_size]  ; prefix length

    ; If prefix is longer than self, return False
    cmp r13, [rbx + PyStrObject.ob_size]
    jg .sw_false

    ; Compare first prefix_len bytes
    lea rdi, [rbx + PyStrObject.data]
    lea rsi, [r12 + PyStrObject.data]
    mov rdx, r13
    ; Manual byte comparison since ap_strcmp needs null-terminated
    xor ecx, ecx
.sw_cmp:
    cmp rcx, r13
    jge .sw_true
    movzx eax, byte [rdi + rcx]
    cmp al, [rsi + rcx]
    jne .sw_false
    inc rcx
    jmp .sw_cmp

.sw_true:
    lea rax, [rel bool_true]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret

.sw_false:
    lea rax, [rel bool_false]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret

.sw_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "must be str, not other type"
    call raise_exception
END_FUNC str_method_startswith

;; ============================================================================
;; str_method_endswith(args, nargs) -> bool_true/bool_false
;; args[0]=self, args[1]=suffix
;; ============================================================================
DEF_FUNC str_method_endswith
    push rbx
    push r12
    push r13
    push r14

    ; Validate args[1] is a string
    mov rax, [rdi + 24]        ; args[1] tag
    cmp eax, TAG_PTR
    jne .ew_type_error
    mov rax, [rdi + 16]
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    jne .ew_type_error

    mov rbx, [rdi]          ; self
    mov r12, [rdi + 16]     ; suffix
    mov r13, [r12 + PyStrObject.ob_size]  ; suffix length
    mov r14, [rbx + PyStrObject.ob_size]  ; self length

    ; If suffix longer than self, False
    cmp r13, r14
    jg .ew_false

    ; Compare last suffix_len bytes of self with suffix
    mov rcx, r14
    sub rcx, r13            ; offset = self_len - suffix_len
    lea rdi, [rbx + PyStrObject.data]
    add rdi, rcx
    lea rsi, [r12 + PyStrObject.data]
    xor ecx, ecx
.ew_cmp:
    cmp rcx, r13
    jge .ew_true
    movzx eax, byte [rdi + rcx]
    cmp al, [rsi + rcx]
    jne .ew_false
    inc rcx
    jmp .ew_cmp

.ew_true:
    lea rax, [rel bool_true]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.ew_false:
    lea rax, [rel bool_false]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.ew_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "must be str, not other type"
    call raise_exception
END_FUNC str_method_endswith

;; ============================================================================
;; str_method_find(args, nargs) -> SmallInt index or -1
;; args[0]=self, args[1]=substr
;; ============================================================================
DEF_FUNC str_method_find
    push rbx
    push r12

    ; Validate args[1] is a string
    mov rax, [rdi + 24]        ; args[1] tag
    cmp eax, TAG_PTR
    jne .find_type_error
    mov rax, [rdi + 16]
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    jne .find_type_error

    mov rbx, [rdi]          ; self
    mov r12, [rdi + 16]     ; substr (now guaranteed heap str)

    ; Use ap_strstr to find substring
    lea rdi, [rbx + PyStrObject.data]
    lea rsi, [r12 + PyStrObject.data]
    call ap_strstr

    test rax, rax
    jz .find_not_found

    ; Compute index: result_ptr - self.data
    lea rcx, [rbx + PyStrObject.data]
    sub rax, rcx
    ; rax = index
    mov rdi, rax
    call int_from_i64

    pop r12
    pop rbx
    leave
    ret

.find_not_found:
    mov rdi, -1
    call int_from_i64

    pop r12
    pop rbx
    leave
    ret

.find_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "must be str, not other type"
    call raise_exception
END_FUNC str_method_find

;; ============================================================================
;; str_method_replace(args, nargs) -> new string with replacements
;; args[0]=self, args[1]=old, args[2]=new
;; Uses callee-saved regs for key state, stack locals for buffer management.
;; ============================================================================
DEF_FUNC str_method_replace
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40             ; [rbp-48]=buf_ptr, [rbp-56]=buf_alloc, [rbp-64]=write_pos, [rbp-72]=self_len, [rbp-80]=pad

    ; Validate args[1] is a string
    mov rax, [rdi + 24]        ; args[1] tag
    cmp eax, TAG_PTR
    jne .repl_type_error
    mov rax, [rdi + 16]
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    jne .repl_type_error

    ; Validate args[2] is a string
    mov rax, [rdi + 40]        ; args[2] tag
    cmp eax, TAG_PTR
    jne .repl_type_error
    mov rax, [rdi + 32]
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    jne .repl_type_error

    ; rbx = self, r12 = old_str, r13 = new_str, r14 = self_len, r15 = scan_pos
    mov rbx, [rdi]          ; self
    mov r12, [rdi + 16]     ; old
    mov r13, [rdi + 32]     ; new
    mov r14, [rbx + PyStrObject.ob_size]
    mov [rbp-72], r14

    ; If old_str is empty, interleave new_str between each char
    cmp qword [r12 + PyStrObject.ob_size], 0
    je .replace_interleave

    ; Allocate initial buffer: self_len * 2 + 64
    lea rdi, [r14 * 2 + 64]
    mov [rbp-56], rdi       ; buf_alloc
    call ap_malloc
    mov [rbp-48], rax       ; buf_ptr
    mov qword [rbp-64], 0   ; write_pos = 0

    xor r15d, r15d          ; r15 = scan position

.replace_scan:
    ; Check if remaining text is long enough for old_str
    mov rax, r14
    sub rax, r15
    cmp rax, [r12 + PyStrObject.ob_size]
    jl .replace_copy_tail

    ; Search for old_str from scan pos
    lea rdi, [rbx + PyStrObject.data]
    add rdi, r15
    lea rsi, [r12 + PyStrObject.data]
    call ap_strstr
    test rax, rax
    jz .replace_copy_tail

    ; Found at rax; compute found_pos relative to self.data start
    lea rcx, [rbx + PyStrObject.data]
    sub rax, rcx            ; rax = found_pos (absolute index in self)
    push rax                ; save found_pos on stack

    ; --- ensure buffer space ---
    mov rcx, rax
    sub rcx, r15            ; prefix_len = found_pos - scan_pos
    mov rdx, [rbp-64]       ; write_pos
    add rdx, rcx
    add rdx, [r13 + PyStrObject.ob_size]
    add rdx, r14            ; generous upper bound for rest
    cmp rdx, [rbp-56]
    jl .replace_space_ok
    shl rdx, 1
    mov [rbp-56], rdx
    mov rdi, [rbp-48]
    mov rsi, rdx
    call ap_realloc
    mov [rbp-48], rax
.replace_space_ok:

    ; --- copy prefix: bytes from scan_pos to found_pos ---
    pop rax                 ; found_pos
    push rax                ; keep on stack
    mov rcx, rax
    sub rcx, r15            ; prefix_len
    test rcx, rcx
    jz .replace_no_prefix

    mov rdi, [rbp-48]
    add rdi, [rbp-64]
    lea rsi, [rbx + PyStrObject.data]
    add rsi, r15
    mov rdx, rcx
    push rcx
    call ap_memcpy
    pop rcx
    add [rbp-64], rcx

.replace_no_prefix:
    ; --- copy new_str ---
    mov rcx, [r13 + PyStrObject.ob_size]
    test rcx, rcx
    jz .replace_adv

    mov rdi, [rbp-48]
    add rdi, [rbp-64]
    lea rsi, [r13 + PyStrObject.data]
    mov rdx, rcx
    push rcx
    call ap_memcpy
    pop rcx
    add [rbp-64], rcx

.replace_adv:
    pop rax                 ; found_pos
    add rax, [r12 + PyStrObject.ob_size]
    mov r15, rax            ; advance scan past old_str
    jmp .replace_scan

.replace_copy_tail:
    ; Copy remaining bytes from scan_pos to end
    mov rcx, r14
    sub rcx, r15
    test rcx, rcx
    jz .replace_make_str

    mov rdi, [rbp-48]
    add rdi, [rbp-64]
    lea rsi, [rbx + PyStrObject.data]
    add rsi, r15
    mov rdx, rcx
    push rcx
    call ap_memcpy
    pop rcx
    add [rbp-64], rcx

.replace_make_str:
    mov rdi, [rbp-48]
    mov rsi, [rbp-64]       ; result length
    call str_new_heap
    push rax

    mov rdi, [rbp-48]
    call ap_free

    pop rax
    mov edx, TAG_PTR
    add rsp, 40
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.replace_interleave:
    ; Interleave: insert new_str before each char and after last
    ; Result = new + ch0 + new + ch1 + ... + ch(n-1) + new
    ; Result len = (self_len + 1) * new_len + self_len
    mov rcx, [r13 + PyStrObject.ob_size]  ; new_len
    lea rax, [r14 + 1]         ; self_len + 1
    imul rax, rcx              ; (self_len + 1) * new_len
    add rax, r14               ; + self_len
    add rax, 1                 ; + NUL
    mov [rbp-56], rax          ; buf_alloc
    mov rdi, rax
    call ap_malloc
    mov [rbp-48], rax          ; buf_ptr
    mov qword [rbp-64], 0      ; write_pos = 0

    xor r15d, r15d             ; scan_pos = 0

.ri_loop:
    ; Copy new_str
    mov rcx, [r13 + PyStrObject.ob_size]
    test rcx, rcx
    jz .ri_skip_new
    mov rdi, [rbp-48]
    add rdi, [rbp-64]
    lea rsi, [r13 + PyStrObject.data]
    mov rdx, rcx
    push rcx
    call ap_memcpy
    pop rcx
    add [rbp-64], rcx
.ri_skip_new:
    ; Check if all chars copied
    cmp r15, r14
    jge .replace_make_str
    ; Copy one char from self
    mov rdi, [rbp-48]
    add rdi, [rbp-64]
    movzx eax, byte [rbx + PyStrObject.data + r15]
    mov [rdi], al
    inc qword [rbp-64]
    inc r15
    jmp .ri_loop

.replace_copy_self:
    lea rdi, [rbx + PyStrObject.data]
    mov rsi, r14
    call str_new_heap
    mov edx, TAG_PTR
    add rsp, 40
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.repl_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "must be str, not other type"
    call raise_exception
END_FUNC str_method_replace

;; ============================================================================
;; str_method_join(args, nargs) -> new string
;; args[0]=self (separator), args[1]=list
;; self.join(iterable)
;; Regs: rbx=self(sep), r12=list, r13=count, r14=sep_len
;; Stack: [rbp-48]=total_len, [rbp-56]=buf_ptr, [rbp-64]=write_pos
;; ============================================================================
DEF_FUNC str_method_join
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32             ; 3 locals + alignment pad = 32

    ; Load separator
    mov r15, rdi             ; save args ptr (r15 free until later)
    mov rbx, [rdi]           ; self (separator) payload
    INCREF rbx               ; borrow → own
    mov r12, [r15 + 16]     ; list (args[1] payload, 16-byte stride)

    mov r13, [r12 + PyListObject.ob_size]  ; item count
    mov r14, [rbx + PyStrObject.ob_size]   ; sep length

    ; If list is empty, return empty string
    test r13, r13
    jz .join_empty

    ; First pass: compute total length
    xor r15d, r15d          ; r15 = total data length
    xor ecx, ecx
.join_len_loop:
    cmp rcx, r13
    jge .join_len_done
    push rcx
    mov rax, [r12 + PyListObject.ob_item]
    mov rdx, [r12 + PyListObject.ob_item_tags]
    mov rax, [rax + rcx * 8]    ; payload
    movzx esi, byte [rdx + rcx] ; tag
    ; Verify element is TAG_PTR and a str
    cmp esi, TAG_PTR
    jne .join_type_error
    mov rdi, [rax + PyObject.ob_type]
    lea r8, [rel str_type]
    cmp rdi, r8
    jne .join_type_error
    add r15, [rax + PyStrObject.ob_size]
    pop rcx
    inc rcx
    jmp .join_len_loop

.join_len_done:
    ; Add separator lengths: sep_len * (count - 1)
    mov rax, r13
    dec rax
    imul rax, r14
    add r15, rax
    mov [rbp-48], r15       ; total_len

    ; Allocate buffer
    lea rdi, [r15 + 8]
    call ap_malloc
    mov [rbp-56], rax       ; buf_ptr
    mov qword [rbp-64], 0   ; write_pos = 0

    ; Second pass: copy data
    xor ecx, ecx
.join_copy_loop:
    cmp rcx, r13
    jge .join_make_str
    push rcx

    ; If not the first item, copy separator
    test rcx, rcx
    jz .join_no_sep

    mov rdi, [rbp-56]
    add rdi, [rbp-64]
    lea rsi, [rbx + PyStrObject.data]
    mov rdx, r14
    call ap_memcpy
    add [rbp-64], r14

.join_no_sep:
    mov rcx, [rsp]          ; reload index
    mov rax, [r12 + PyListObject.ob_item]
    mov rax, [rax + rcx * 8]    ; item payload

    ; Heap string element
    mov rdx, [rax + PyStrObject.ob_size]
    push rdx                ; save item_len
    mov rdi, [rbp-56]
    add rdi, [rbp-64]
    lea rsi, [rax + PyStrObject.data]
    call ap_memcpy
    pop rdx                 ; item_len
    add [rbp-64], rdx
    pop rcx
    inc rcx
    jmp .join_copy_loop

.join_make_str:
    mov rdi, [rbp-56]
    mov rsi, [rbp-48]       ; total_len
    call str_new_heap
    push rax

    mov rdi, [rbp-56]
    call ap_free

    ; DECREF owned separator
    mov rdi, rbx
    call obj_decref

    pop rax
    mov edx, TAG_PTR
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.join_empty:
    ; DECREF owned separator
    mov rdi, rbx
    call obj_decref

    lea rdi, [rel empty_str_cstr]
    call str_from_cstr_heap
    mov edx, TAG_PTR
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.join_type_error:
    pop rcx                 ; clean up pushed index from len_loop
    mov rdi, rbx
    call obj_decref         ; DECREF owned separator
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "sequence item: expected str instance"
    call raise_exception
END_FUNC str_method_join

;; ============================================================================
;; str_method_split(args, nargs) -> list of strings
;; If nargs==1: split by whitespace
;; If nargs==2: split by args[1]
;; ============================================================================
DEF_FUNC str_method_split
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8              ; align

    mov rbx, [rdi]          ; self
    mov r14, rsi            ; nargs
    ; Save args[1] if present
    cmp r14, 2
    jl .split_no_sep

    ; Validate args[1] is a string
    mov rax, [rdi + 24]        ; args[1] tag
    cmp eax, TAG_PTR
    jne .spl_type_error
    mov rax, [rdi + 16]
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    jne .spl_type_error

    mov r15, [rdi + 16]     ; separator string
    jmp .split_by_sep

.split_no_sep:
    ; Split by whitespace
    mov r12, [rbx + PyStrObject.ob_size]  ; self length

    ; Create result list
    mov rdi, 8
    call list_new
    mov r13, rax            ; r13 = result list

    ; Scan through self
    xor ecx, ecx            ; ecx = position
.ws_scan:
    ; Skip leading whitespace
    cmp rcx, r12
    jge .ws_done
    movzx eax, byte [rbx + PyStrObject.data + rcx]
    cmp al, ' '
    je .ws_skip
    cmp al, 9
    je .ws_skip
    cmp al, 10
    je .ws_skip
    cmp al, 13
    je .ws_skip
    jmp .ws_word_start
.ws_skip:
    inc rcx
    jmp .ws_scan

.ws_word_start:
    ; Found start of word at rcx
    mov r15, rcx            ; word start
.ws_word_scan:
    inc rcx
    cmp rcx, r12
    jge .ws_word_end
    movzx eax, byte [rbx + PyStrObject.data + rcx]
    cmp al, ' '
    je .ws_word_end
    cmp al, 9
    je .ws_word_end
    cmp al, 10
    je .ws_word_end
    cmp al, 13
    je .ws_word_end
    jmp .ws_word_scan

.ws_word_end:
    ; Word from r15 to rcx (exclusive)
    push rcx
    lea rdi, [rbx + PyStrObject.data]
    add rdi, r15
    mov rsi, rcx
    sub rsi, r15            ; length
    call str_new_heap
    ; Append to list
    mov rdi, r13
    mov rsi, rax
    push rax
    mov edx, TAG_PTR
    call list_append
    pop rdi
    call obj_decref         ; list_append did INCREF
    pop rcx
    jmp .ws_scan

.ws_done:
    mov rax, r13
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    mov edx, TAG_PTR
    leave
    ret

.split_by_sep:
    ; Split by separator string r15
    mov r12, [rbx + PyStrObject.ob_size]  ; self length
    mov r14, [r15 + PyStrObject.ob_size]  ; sep length

    ; Create result list
    mov rdi, 8
    call list_new
    mov r13, rax            ; r13 = result list

    ; If sep is empty, raise ValueError
    test r14, r14
    jz .split_empty_sep

    xor ecx, ecx            ; scan position
.sep_scan:
    push rcx                ; save scan pos

    ; Search for separator starting at current position
    lea rdi, [rbx + PyStrObject.data]
    add rdi, rcx
    lea rsi, [r15 + PyStrObject.data]
    call ap_strstr
    pop rcx

    test rax, rax
    jz .sep_tail

    ; Found separator at rax
    lea rdx, [rbx + PyStrObject.data]
    sub rax, rdx            ; found_pos in self
    push rax                ; save found_pos

    ; Create substring from rcx to found_pos
    lea rdi, [rbx + PyStrObject.data]
    add rdi, rcx
    mov rsi, rax
    sub rsi, rcx            ; length = found_pos - scan_pos
    call str_new_heap
    mov rdi, r13
    mov rsi, rax
    push rax
    mov edx, TAG_PTR
    call list_append
    pop rdi
    call obj_decref

    pop rcx                 ; found_pos
    add rcx, r14            ; advance past separator
    jmp .sep_scan

.sep_tail:
    ; Copy remaining string from rcx to end
    lea rdi, [rbx + PyStrObject.data]
    add rdi, rcx
    mov rsi, r12
    sub rsi, rcx            ; remaining length
    call str_new_heap
    mov rdi, r13
    mov rsi, rax
    push rax
    mov edx, TAG_PTR
    call list_append
    pop rdi
    call obj_decref

    mov rax, r13
    mov edx, TAG_PTR
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.split_empty_sep:
    lea rdi, [rel exc_ValueError_type]
    CSTRING rsi, "empty separator"
    call raise_exception

.spl_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "must be str, not other type"
    call raise_exception
END_FUNC str_method_split


;; ============================================================================
;; str_method_format(args, nargs) -> new formatted string
;; args[0]=self (format string), args[1..]=positional arguments
;; Handles {} (auto-index) and {N} (explicit index).
;; ============================================================================
DEF_FUNC str_method_format
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 24             ; [rbp-48]=buf, [rbp-56]=buf_used, [rbp-64]=buf_cap

    mov rbx, rdi            ; args array
    mov r14, rsi            ; nargs

    ; Get format string data
    mov rax, [rbx]          ; self = format string
    lea r12, [rax + PyStrObject.data]  ; r12 = fmt data ptr
    mov r13d, [rax + PyStrObject.ob_size] ; r13 = fmt length

    ; Allocate initial output buffer
    lea rdi, [r13 + 64]    ; generous initial size
    call ap_malloc
    mov [rbp-48], rax       ; buf
    mov qword [rbp-56], 0   ; buf_used = 0
    lea rax, [r13 + 64]
    mov [rbp-64], rax       ; buf_cap

    xor ecx, ecx            ; ecx = source index
    xor r15d, r15d          ; r15d = auto-index counter

.fmt_loop:
    cmp ecx, r13d
    jge .fmt_done
    movzx eax, byte [r12 + rcx]
    cmp al, '{'
    je .fmt_brace
    cmp al, '}'
    je .fmt_close_brace
    ; Regular char — append to buffer
    push rcx
    ; Ensure space
    mov rdi, [rbp-56]       ; used
    inc rdi                 ; need 1 more
    cmp rdi, [rbp-64]
    jbe .fmt_char_ok
    ; Grow buffer
    mov rdi, [rbp-64]
    shl rdi, 1
    mov [rbp-64], rdi
    mov rsi, rdi
    mov rdi, [rbp-48]
    call ap_realloc
    mov [rbp-48], rax
.fmt_char_ok:
    pop rcx
    mov rdi, [rbp-48]
    mov rax, [rbp-56]
    movzx edx, byte [r12 + rcx]
    mov [rdi + rax], dl
    inc qword [rbp-56]
    inc ecx
    jmp .fmt_loop

.fmt_brace:
    inc ecx                 ; skip '{'
    cmp ecx, r13d
    jge .fmt_done
    movzx eax, byte [r12 + rcx]
    ; Check for {{ (literal brace)
    cmp al, '{'
    je .fmt_literal_brace
    ; Check for } (empty placeholder = auto-index)
    cmp al, '}'
    je .fmt_auto_index
    ; Check for digit (explicit index)
    cmp al, '0'
    jb .fmt_done            ; unexpected char, bail
    cmp al, '9'
    ja .fmt_done
    ; Parse number
    xor edx, edx            ; edx = arg_index
.fmt_parse_num:
    movzx eax, byte [r12 + rcx]
    cmp al, '}'
    je .fmt_have_index
    sub al, '0'
    imul edx, 10
    movzx eax, al
    add edx, eax
    inc ecx
    cmp ecx, r13d
    jl .fmt_parse_num
    jmp .fmt_done
.fmt_have_index:
    inc ecx                 ; skip '}'
    jmp .fmt_insert_arg

.fmt_auto_index:
    inc ecx                 ; skip '}'
    mov edx, r15d           ; edx = auto-index
    inc r15d
    ; fall through to .fmt_insert_arg

.fmt_insert_arg:
    ; edx = arg index (0-based among format args, which are args[1..])
    lea eax, [edx + 1]     ; args index (skip self)
    cmp rax, r14
    jge .fmt_loop           ; out of range, skip
    push rcx
    push rdx
    ; Get the arg object and convert to string
    shl rax, 4              ; offset = index * 16
    mov rdi, [rbx + rax]    ; arg object payload
    mov r8, [rbx + rax + 8]  ; arg tag
    ; Convert arg to string via obj_str(payload, tag)
    ; obj_str handles all tags: SmallInt, Float, Bool, None, TAG_PTR
    push rdi
    cmp r8d, TAG_PTR
    jne .fmt_inline_str      ; SmallInt, Float, Bool, None → obj_str
    ; TAG_PTR path: call tp_str directly (avoids extra push/pop in obj_str)
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_str]
    test rax, rax
    jz .fmt_use_repr
    pop rdi
    call rax
    jmp .fmt_heap_str
.fmt_use_repr:
    pop rdi
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_repr]
    test rax, rax
    jz .fmt_skip_arg
    call rax
    jmp .fmt_heap_str
.fmt_inline_str:
    pop rdi
    mov esi, r8d           ; tag
    call obj_str           ; handles SmallInt, Float, Bool, None
.fmt_heap_str:
    push rax                ; save str obj for DECREF
    mov edx, [rax + PyStrObject.ob_size]
    lea rsi, [rax + PyStrObject.data]
    ; Ensure buffer has space
    mov rdi, [rbp-56]
    add rdi, rdx
    cmp rdi, [rbp-64]
    jbe .fmt_copy_ok
    mov rdi, [rbp-64]
.fmt_grow_copy:
    shl rdi, 1
    mov rax, [rbp-56]
    add rax, rdx
    cmp rdi, rax
    jb .fmt_grow_copy
    mov [rbp-64], rdi
    mov rsi, rdi
    mov rdi, [rbp-48]
    call ap_realloc
    mov [rbp-48], rax
    ; Re-read str data (rax was clobbered)
    mov rax, [rsp]          ; str obj
    mov edx, [rax + PyStrObject.ob_size]
    lea rsi, [rax + PyStrObject.data]
.fmt_copy_ok:
    ; Copy string data
    mov rdi, [rbp-48]
    add rdi, [rbp-56]
    xor ecx, ecx
.fmt_copy_str:
    cmp ecx, edx
    jge .fmt_copy_done
    mov al, [rsi + rcx]
    mov [rdi + rcx], al
    inc ecx
    jmp .fmt_copy_str
.fmt_copy_done:
    movzx eax, dx
    add [rbp-56], rax

    ; DECREF the temporary string
    pop rdi                 ; str obj
    call obj_decref
.fmt_skip_arg:
    pop rdx
    pop rcx
    jmp .fmt_loop

.fmt_literal_brace:
    ; {{ → output single {
    push rcx
    mov rdi, [rbp-48]
    mov rax, [rbp-56]
    mov byte [rdi + rax], '{'
    inc qword [rbp-56]
    pop rcx
    inc ecx                 ; skip second {
    jmp .fmt_loop

.fmt_close_brace:
    ; }} → output single }
    inc ecx                 ; skip first }
    cmp ecx, r13d
    jge .fmt_done
    movzx eax, byte [r12 + rcx]
    cmp al, '}'
    jne .fmt_loop           ; lone } — ignore (CPython raises error, we skip)
    push rcx
    mov rdi, [rbp-48]
    mov rax, [rbp-56]
    mov byte [rdi + rax], '}'
    inc qword [rbp-56]
    pop rcx
    inc ecx                 ; skip second }
    jmp .fmt_loop

.fmt_done:
    ; NUL-terminate and create string
    mov rdi, [rbp-48]
    mov rax, [rbp-56]
    mov byte [rdi + rax], 0
    call str_from_cstr_heap
    push rax

    ; Free buffer
    mov rdi, [rbp-48]
    call ap_free

    pop rax
    mov edx, TAG_PTR
    add rsp, 24
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC str_method_format

;; ============================================================================
;; str_method_format_map(args, nargs) -> formatted string
;; args[0]=self (format string), args[1]=mapping (dict)
;; Replaces {key} with mapping[key].
;; ============================================================================
FM_ARGS   equ 8
FM_MAP    equ 16
FM_BUF    equ 24
FM_USED   equ 32
FM_CAP    equ 40
FM_FRAME  equ 48

DEF_FUNC str_method_format_map, FM_FRAME
    push rbx
    push r12
    push r13
    push r14
    push r15

    cmp rsi, 2
    jne .fmap_error

    mov [rbp - FM_ARGS], rdi
    mov rax, [rdi]              ; self = format string
    mov rcx, [rdi + 16]         ; mapping dict
    mov [rbp - FM_MAP], rcx

    lea r12, [rax + PyStrObject.data]   ; r12 = fmt data
    mov r13d, [rax + PyStrObject.ob_size] ; r13 = fmt len

    ; Allocate output buffer
    lea rdi, [r13 + 64]
    call ap_malloc
    mov [rbp - FM_BUF], rax
    mov qword [rbp - FM_USED], 0
    lea rax, [r13 + 64]
    mov [rbp - FM_CAP], rax

    xor ecx, ecx               ; source index

.fmap_loop:
    cmp ecx, r13d
    jge .fmap_done
    movzx eax, byte [r12 + rcx]
    cmp al, '{'
    je .fmap_brace
    cmp al, '}'
    je .fmap_close_brace

    ; Regular char — append
    push rcx
    mov rdi, [rbp - FM_BUF]
    mov rax, [rbp - FM_USED]
    movzx edx, byte [r12 + rcx]
    mov [rdi + rax], dl
    inc qword [rbp - FM_USED]
    pop rcx
    inc ecx
    jmp .fmap_loop

.fmap_brace:
    inc ecx
    cmp ecx, r13d
    jge .fmap_done
    movzx eax, byte [r12 + rcx]
    cmp al, '{'
    je .fmap_literal_open

    ; Extract key name until '}'
    mov r14d, ecx              ; key start
.fmap_key_scan:
    cmp ecx, r13d
    jge .fmap_done
    movzx eax, byte [r12 + rcx]
    cmp al, '}'
    je .fmap_have_key
    inc ecx
    jmp .fmap_key_scan

.fmap_have_key:
    ; Key is from r14 to ecx (exclusive)
    push rcx
    inc ecx                     ; skip '}'
    push rcx                    ; save next source pos

    ; Create key string
    lea rdi, [r12 + r14]
    mov esi, ecx
    dec esi
    sub esi, r14d               ; key length
    movzx esi, si               ; zero-extend
    call str_new_heap
    push rax                    ; save key str

    ; Look up in mapping: dict_get(dict, key, key_tag)
    mov rdi, [rbp - FM_MAP]
    mov rsi, rax
    mov edx, TAG_PTR
    call dict_get
    ; rax = value payload, edx = value tag
    push rax
    push rdx

    ; DECREF key
    mov rdi, [rsp + 16]         ; key str
    call obj_decref

    ; Convert value to string
    pop rsi                     ; value tag
    pop rdi                     ; value payload
    call obj_str
    ; rax = result payload, edx = tag
    push rax                    ; save str obj for DECREF

    ; Copy string data to buffer
    mov edx, [rax + PyStrObject.ob_size]
    ; Ensure buffer space
    mov rdi, [rbp - FM_USED]
    add rdi, rdx
    cmp rdi, [rbp - FM_CAP]
    jbe .fmap_copy_ok
    mov rdi, [rbp - FM_CAP]
    shl rdi, 1
    add rdi, rdx
    mov [rbp - FM_CAP], rdi
    push rdx
    mov rsi, rdi
    mov rdi, [rbp - FM_BUF]
    call ap_realloc
    mov [rbp - FM_BUF], rax
    pop rdx
    mov rax, [rsp]              ; re-read str obj
.fmap_copy_ok:
    test edx, edx
    jz .fmap_val_done
    push rdx
    mov rdi, [rbp - FM_BUF]
    add rdi, [rbp - FM_USED]
    lea rsi, [rax + PyStrObject.data]
    movzx edx, dx
    call ap_memcpy
    pop rdx
    movzx eax, dx
    add [rbp - FM_USED], rax

.fmap_val_done:
    ; DECREF temp str
    pop rdi
    call obj_decref
    pop rax                     ; discard saved key str slot
    pop rcx                     ; next source pos
    pop rax                     ; discard saved old ecx
    jmp .fmap_loop

.fmap_literal_open:
    push rcx
    mov rdi, [rbp - FM_BUF]
    mov rax, [rbp - FM_USED]
    mov byte [rdi + rax], '{'
    inc qword [rbp - FM_USED]
    pop rcx
    inc ecx
    jmp .fmap_loop

.fmap_close_brace:
    inc ecx
    cmp ecx, r13d
    jge .fmap_done
    movzx eax, byte [r12 + rcx]
    cmp al, '}'
    jne .fmap_loop
    push rcx
    mov rdi, [rbp - FM_BUF]
    mov rax, [rbp - FM_USED]
    mov byte [rdi + rax], '}'
    inc qword [rbp - FM_USED]
    pop rcx
    inc ecx
    jmp .fmap_loop

.fmap_done:
    mov rdi, [rbp - FM_BUF]
    mov rsi, [rbp - FM_USED]
    call str_new_heap
    push rax

    mov rdi, [rbp - FM_BUF]
    call ap_free

    pop rax
    mov edx, TAG_PTR
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.fmap_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "format_map() takes exactly one argument"
    call raise_exception
END_FUNC str_method_format_map

;; ============================================================================
;; str_method_lstrip(args, nargs) -> new string with left whitespace removed
;; args[0] = self (PyStrObject*)
;; ============================================================================
DEF_FUNC str_method_lstrip
    push rbx
    push r12
    push r13

    mov rax, [rdi]          ; self = args[0]
    mov rbx, rax            ; rbx = self
    mov r12, [rbx + PyStrObject.ob_size]  ; r12 = length

    ; Find start (skip leading whitespace)
    xor r13d, r13d          ; r13 = start index
.lstrip_left:
    cmp r13, r12
    jge .lstrip_empty
    movzx eax, byte [rbx + PyStrObject.data + r13]
    cmp al, ' '
    je .lstrip_left_next
    cmp al, 9              ; tab
    je .lstrip_left_next
    cmp al, 10             ; newline
    je .lstrip_left_next
    cmp al, 13             ; carriage return
    je .lstrip_left_next
    cmp al, 11             ; vertical tab
    je .lstrip_left_next
    cmp al, 12             ; form feed
    je .lstrip_left_next
    jmp .lstrip_make
.lstrip_left_next:
    inc r13
    jmp .lstrip_left

.lstrip_empty:
    ; All whitespace - return empty string
    lea rdi, [rel empty_str_cstr]
    call str_from_cstr_heap
    jmp .lstrip_ret

.lstrip_make:
    ; Create new string from [start, end)
    lea rdi, [rbx + PyStrObject.data]
    add rdi, r13
    mov rsi, r12
    sub rsi, r13            ; length = len - start
    call str_new_heap

.lstrip_ret:
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC str_method_lstrip

;; ============================================================================
;; str_method_rstrip(args, nargs) -> new string with right whitespace removed
;; args[0] = self (PyStrObject*)
;; ============================================================================
DEF_FUNC str_method_rstrip
    push rbx
    push r12
    push r13

    mov rax, [rdi]          ; self = args[0]
    mov rbx, rax            ; rbx = self
    mov r12, [rbx + PyStrObject.ob_size]  ; r12 = length

    ; Find end (skip trailing whitespace)
    mov r13, r12            ; r13 = end (exclusive)
.rstrip_right:
    cmp r13, 0
    jle .rstrip_empty
    movzx eax, byte [rbx + PyStrObject.data + r13 - 1]
    cmp al, ' '
    je .rstrip_right_next
    cmp al, 9              ; tab
    je .rstrip_right_next
    cmp al, 10             ; newline
    je .rstrip_right_next
    cmp al, 13             ; carriage return
    je .rstrip_right_next
    cmp al, 11             ; vertical tab
    je .rstrip_right_next
    cmp al, 12             ; form feed
    je .rstrip_right_next
    jmp .rstrip_make
.rstrip_right_next:
    dec r13
    jmp .rstrip_right

.rstrip_empty:
    ; All whitespace - return empty string
    lea rdi, [rel empty_str_cstr]
    call str_from_cstr_heap
    jmp .rstrip_ret

.rstrip_make:
    ; Create new string from [0, end)
    lea rdi, [rbx + PyStrObject.data]
    mov rsi, r13            ; length = end
    call str_new_heap

.rstrip_ret:
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC str_method_rstrip

;; ============================================================================
;; str_method_count(args, nargs) -> SmallInt count of occurrences
;; args[0]=self, args[1]=sub
;; ============================================================================
DEF_FUNC str_method_count
    push rbx
    push r12
    push r13
    push r14

    ; Validate args[1] is a string
    mov rax, [rdi + 24]        ; args[1] tag
    cmp eax, TAG_PTR
    jne .count_type_error
    mov rax, [rdi + 16]
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    jne .count_type_error

    mov rbx, [rdi]          ; self
    mov r12, [rdi + 16]     ; substr (now guaranteed heap str)
    xor r13d, r13d          ; r13 = count
    mov r14, [r12 + PyStrObject.ob_size]  ; sub length

    ; If sub is empty, return len+1
    test r14, r14
    jz .count_empty_sub

    ; Start scanning from self.data
    lea rdi, [rbx + PyStrObject.data]

.count_scan:
    lea rsi, [r12 + PyStrObject.data]
    push rdi
    call ap_strstr
    pop rdi                 ; restore (not needed, but stack balance)
    test rax, rax
    jz .count_done

    ; Found one occurrence
    inc r13
    ; Advance past this match
    lea rdi, [rax + r14]    ; move past the match
    jmp .count_scan

.count_empty_sub:
    ; Empty substring: count = len(self) + 1
    mov r13, [rbx + PyStrObject.ob_size]
    inc r13

.count_done:
    mov rdi, r13
    call int_from_i64
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.count_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "must be str, not other type"
    call raise_exception
END_FUNC str_method_count

;; ============================================================================
;; str_method_index(args, nargs) -> SmallInt index (raises ValueError if not found)
;; args[0]=self, args[1]=substr
;; ============================================================================
DEF_FUNC str_method_index
    push rbx
    push r12

    ; Validate args[1] is a string
    mov rax, [rdi + 24]        ; args[1] tag
    cmp eax, TAG_PTR
    jne .idx_type_error
    mov rax, [rdi + 16]
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    jne .idx_type_error

    mov rbx, [rdi]          ; self
    mov r12, [rdi + 16]     ; substr

    ; Use ap_strstr to find substring
    lea rdi, [rbx + PyStrObject.data]
    lea rsi, [r12 + PyStrObject.data]
    call ap_strstr

    test rax, rax
    jz .str_index_not_found

    ; Compute index: result_ptr - self.data
    lea rcx, [rbx + PyStrObject.data]
    sub rax, rcx
    ; rax = index
    mov rdi, rax
    call int_from_i64

    pop r12
    pop rbx
    leave
    ret

.str_index_not_found:
    lea rdi, [rel exc_ValueError_type]
    CSTRING rsi, "substring not found"
    call raise_exception

.idx_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "must be str, not other type"
    call raise_exception
END_FUNC str_method_index

;; ============================================================================
;; str_method_rfind(args, nargs) -> SmallInt index or -1
;; args[0]=self, args[1]=substr
;; Find rightmost occurrence of substr in self.
;; ============================================================================
DEF_FUNC str_method_rfind
    push rbx
    push r12
    push r13
    push r14

    ; Validate args[1] is a string
    mov rax, [rdi + 24]        ; args[1] tag
    cmp eax, TAG_PTR
    jne .rfind_type_error
    mov rax, [rdi + 16]
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    jne .rfind_type_error

    mov rbx, [rdi]          ; self
    mov r12, [rdi + 16]     ; substr (now guaranteed heap str)
    mov r13, [rbx + PyStrObject.ob_size]   ; self length
    mov r14, [r12 + PyStrObject.ob_size]   ; sub length

    ; If sub_len > self_len, return -1
    cmp r14, r13
    jg .rfind_not_found

    ; If sub_len == 0, return self_len
    test r14, r14
    jz .rfind_empty_sub

    ; Walk backward from (self_len - sub_len) down to 0
    mov rcx, r13
    sub rcx, r14            ; rcx = last possible start position

.rfind_loop:
    cmp rcx, 0
    jl .rfind_not_found

    ; Compare sub with self[rcx..rcx+sub_len]
    push rcx
    lea rdi, [rbx + PyStrObject.data]
    add rdi, rcx
    lea rsi, [r12 + PyStrObject.data]
    mov rdx, r14
    call ap_memcmp
    pop rcx

    test eax, eax
    jz .rfind_found

    dec rcx
    jmp .rfind_loop

.rfind_found:
    mov rdi, rcx
    call int_from_i64
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.rfind_empty_sub:
    mov rdi, r13
    call int_from_i64
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.rfind_not_found:
    mov rdi, -1
    call int_from_i64
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.rfind_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "must be str, not other type"
    call raise_exception
END_FUNC str_method_rfind

;; ============================================================================
;; str_method_isdigit(args, nargs) -> bool_true/bool_false
;; args[0] = self
;; Returns True if all chars are digits and len>0, else False
;; ============================================================================
DEF_FUNC str_method_isdigit
    mov rax, [rdi]          ; self
    mov rcx, [rax + PyStrObject.ob_size]

    ; Empty string -> False
    test rcx, rcx
    jz .isdigit_false

    xor edx, edx            ; index
.isdigit_loop:
    cmp rdx, rcx
    jge .isdigit_true
    movzx esi, byte [rax + PyStrObject.data + rdx]
    cmp sil, '0'
    jb .isdigit_false
    cmp sil, '9'
    ja .isdigit_false
    inc rdx
    jmp .isdigit_loop

.isdigit_true:
    lea rax, [rel bool_true]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    ret

.isdigit_false:
    lea rax, [rel bool_false]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    ret
END_FUNC str_method_isdigit

;; ============================================================================
;; str_method_isalpha(args, nargs) -> bool_true/bool_false
;; args[0] = self
;; Returns True if all chars are alphabetic and len>0, else False
;; ============================================================================
DEF_FUNC str_method_isalpha
    mov rax, [rdi]          ; self
    mov rcx, [rax + PyStrObject.ob_size]

    ; Empty string -> False
    test rcx, rcx
    jz .isalpha_false

    xor edx, edx            ; index
.isalpha_loop:
    cmp rdx, rcx
    jge .isalpha_true
    movzx esi, byte [rax + PyStrObject.data + rdx]
    cmp sil, 'A'
    jb .isalpha_false
    cmp sil, 'Z'
    jbe .isalpha_next        ; A-Z is alpha
    cmp sil, 'a'
    jb .isalpha_false
    cmp sil, 'z'
    ja .isalpha_false
.isalpha_next:
    inc rdx
    jmp .isalpha_loop

.isalpha_true:
    lea rax, [rel bool_true]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    ret

.isalpha_false:
    lea rax, [rel bool_false]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    ret
END_FUNC str_method_isalpha

;; ============================================================================
;; str_method_isalnum(args, nargs) -> bool_true/bool_false
;; args[0] = self
;; Returns True if all chars are alphanumeric (0-9, A-Z, a-z) and len>0
;; ============================================================================
DEF_FUNC str_method_isalnum
    mov rax, [rdi]          ; self
    mov rcx, [rax + PyStrObject.ob_size]

    ; Empty string -> False
    test rcx, rcx
    jz .isalnum_false

    xor edx, edx            ; index
.isalnum_loop:
    cmp rdx, rcx
    jge .isalnum_true
    movzx esi, byte [rax + PyStrObject.data + rdx]
    cmp sil, '0'
    jb .isalnum_false
    cmp sil, '9'
    jbe .isalnum_next        ; 0-9
    cmp sil, 'A'
    jb .isalnum_false
    cmp sil, 'Z'
    jbe .isalnum_next        ; A-Z
    cmp sil, 'a'
    jb .isalnum_false
    cmp sil, 'z'
    ja .isalnum_false
.isalnum_next:
    inc rdx
    jmp .isalnum_loop

.isalnum_true:
    lea rax, [rel bool_true]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    ret

.isalnum_false:
    lea rax, [rel bool_false]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    ret
END_FUNC str_method_isalnum

;; ============================================================================
;; str_method_isspace(args, nargs) -> bool_true/bool_false
;; args[0] = self
;; Returns True if all chars are whitespace (space/tab/newline/CR/VT/FF) and len>0
;; ============================================================================
DEF_FUNC str_method_isspace
    mov rax, [rdi]          ; self
    mov rcx, [rax + PyStrObject.ob_size]

    ; Empty string -> False
    test rcx, rcx
    jz .isspace_false

    xor edx, edx            ; index
.isspace_loop:
    cmp rdx, rcx
    jge .isspace_true
    movzx esi, byte [rax + PyStrObject.data + rdx]
    cmp sil, 0x20           ; space
    je .isspace_next
    cmp sil, 0x09           ; tab
    jb .isspace_false
    cmp sil, 0x0D           ; tab(09), newline(0A), VT(0B), FF(0C), CR(0D)
    ja .isspace_false
.isspace_next:
    inc rdx
    jmp .isspace_loop

.isspace_true:
    lea rax, [rel bool_true]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    ret

.isspace_false:
    lea rax, [rel bool_false]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    ret
END_FUNC str_method_isspace

;; ============================================================================
;; str_method_isupper(args, nargs) -> bool_true/bool_false
;; args[0] = self
;; Returns True if all cased chars are uppercase, and there is at least one cased char
;; ============================================================================
DEF_FUNC str_method_isupper
    mov rax, [rdi]          ; self
    mov rcx, [rax + PyStrObject.ob_size]

    ; Empty string -> False
    test rcx, rcx
    jz .isupper_false

    xor edx, edx            ; index
    xor r8d, r8d            ; has_cased flag
.isupper_loop:
    cmp rdx, rcx
    jge .isupper_check_cased
    movzx esi, byte [rax + PyStrObject.data + rdx]
    cmp sil, 'A'
    jb .isupper_next         ; non-alpha, skip
    cmp sil, 'Z'
    jbe .isupper_found_upper ; A-Z: uppercase, good
    cmp sil, 'a'
    jb .isupper_next         ; non-alpha, skip
    cmp sil, 'z'
    jbe .isupper_false       ; a-z: lowercase, fail
.isupper_next:
    inc rdx
    jmp .isupper_loop
.isupper_found_upper:
    mov r8d, 1               ; found at least one cased char
    inc rdx
    jmp .isupper_loop
.isupper_check_cased:
    test r8d, r8d
    jz .isupper_false        ; no cased chars found

    lea rax, [rel bool_true]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    ret

.isupper_false:
    lea rax, [rel bool_false]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    ret
END_FUNC str_method_isupper

;; ============================================================================
;; str_method_islower(args, nargs) -> bool_true/bool_false
;; args[0] = self
;; Returns True if all cased chars are lowercase, and there is at least one cased char
;; ============================================================================
DEF_FUNC str_method_islower
    mov rax, [rdi]          ; self
    mov rcx, [rax + PyStrObject.ob_size]

    ; Empty string -> False
    test rcx, rcx
    jz .islower_false

    xor edx, edx            ; index
    xor r8d, r8d            ; has_cased flag
.islower_loop:
    cmp rdx, rcx
    jge .islower_check_cased
    movzx esi, byte [rax + PyStrObject.data + rdx]
    cmp sil, 'a'
    jb .islower_check_upper
    cmp sil, 'z'
    jbe .islower_found_lower ; a-z: lowercase, good
    jmp .islower_next        ; > 'z', non-alpha, skip
.islower_check_upper:
    cmp sil, 'A'
    jb .islower_next         ; non-alpha, skip
    cmp sil, 'Z'
    jbe .islower_false       ; A-Z: uppercase, fail
.islower_next:
    inc rdx
    jmp .islower_loop
.islower_found_lower:
    mov r8d, 1               ; found at least one cased char
    inc rdx
    jmp .islower_loop
.islower_check_cased:
    test r8d, r8d
    jz .islower_false        ; no cased chars found

    lea rax, [rel bool_true]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    ret

.islower_false:
    lea rax, [rel bool_false]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    ret
END_FUNC str_method_islower

;; ============================================================================
;; str_method_title(args, nargs) -> new titlecased string
;; Uppercase after non-alpha, lowercase after alpha
;; ============================================================================
DEF_FUNC str_method_title
    push rbx
    push r12
    push r13

    mov rbx, [rdi]          ; self
    mov r12, [rbx + PyStrObject.ob_size]

    lea rdi, [rbx + PyStrObject.data]
    mov rsi, r12
    call str_new_heap
    mov r13, rax

    xor ecx, ecx            ; i = 0
    mov r8d, 1               ; prev_is_sep = true (start of string)
.title_loop:
    cmp rcx, r12
    jge .title_done
    movzx eax, byte [r13 + PyStrObject.data + rcx]
    ; Check if alpha
    cmp al, 'A'
    jb .title_not_alpha
    cmp al, 'Z'
    jbe .title_is_upper
    cmp al, 'a'
    jb .title_not_alpha
    cmp al, 'z'
    ja .title_not_alpha
    ; lowercase char
    test r8d, r8d
    jz .title_to_lower       ; prev was alpha → stay lower
    ; prev was non-alpha → capitalize
    sub al, 32
    mov [r13 + PyStrObject.data + rcx], al
    xor r8d, r8d             ; prev_is_sep = false
    jmp .title_next
.title_is_upper:
    test r8d, r8d
    jnz .title_keep_upper     ; prev was non-alpha → keep upper
    ; prev was alpha → lowercase it
    add al, 32
    mov [r13 + PyStrObject.data + rcx], al
    xor r8d, r8d
    jmp .title_next
.title_keep_upper:
    xor r8d, r8d
    jmp .title_next
.title_to_lower:
    ; already lowercase, prev was alpha → keep as-is
    xor r8d, r8d
    jmp .title_next
.title_not_alpha:
    mov r8d, 1               ; prev_is_sep = true
.title_next:
    inc rcx
    jmp .title_loop
.title_done:
    mov rax, r13
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC str_method_title

;; ============================================================================
;; str_method_capitalize(args, nargs) -> new string
;; First char upper, rest lower
;; ============================================================================
DEF_FUNC str_method_capitalize
    push rbx
    push r12
    push r13

    mov rbx, [rdi]
    mov r12, [rbx + PyStrObject.ob_size]

    lea rdi, [rbx + PyStrObject.data]
    mov rsi, r12
    call str_new_heap
    mov r13, rax

    ; First char → upper
    test r12, r12
    jz .cap_done
    movzx eax, byte [r13 + PyStrObject.data]
    cmp al, 'a'
    jb .cap_rest
    cmp al, 'z'
    ja .cap_rest
    sub al, 32
    mov [r13 + PyStrObject.data], al

.cap_rest:
    ; Remaining chars → lower
    mov rcx, 1
.cap_loop:
    cmp rcx, r12
    jge .cap_done
    movzx eax, byte [r13 + PyStrObject.data + rcx]
    cmp al, 'A'
    jb .cap_next
    cmp al, 'Z'
    ja .cap_next
    add al, 32
    mov [r13 + PyStrObject.data + rcx], al
.cap_next:
    inc rcx
    jmp .cap_loop
.cap_done:
    mov rax, r13
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC str_method_capitalize

;; ============================================================================
;; str_method_swapcase(args, nargs) -> new string
;; Upper→lower, lower→upper
;; ============================================================================
DEF_FUNC str_method_swapcase
    push rbx
    push r12
    push r13

    mov rbx, [rdi]
    mov r12, [rbx + PyStrObject.ob_size]

    lea rdi, [rbx + PyStrObject.data]
    mov rsi, r12
    call str_new_heap
    mov r13, rax

    xor ecx, ecx
.swap_loop:
    cmp rcx, r12
    jge .swap_done
    movzx eax, byte [r13 + PyStrObject.data + rcx]
    cmp al, 'A'
    jb .swap_next
    cmp al, 'Z'
    jbe .swap_to_lower
    cmp al, 'a'
    jb .swap_next
    cmp al, 'z'
    ja .swap_next
    ; lowercase → upper
    sub al, 32
    mov [r13 + PyStrObject.data + rcx], al
    jmp .swap_next
.swap_to_lower:
    add al, 32
    mov [r13 + PyStrObject.data + rcx], al
.swap_next:
    inc rcx
    jmp .swap_loop
.swap_done:
    mov rax, r13
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC str_method_swapcase

;; ============================================================================
;; str_method_casefold(args, nargs) -> new string
;; ASCII casefold = lowercase (full Unicode casefold deferred)
;; ============================================================================
DEF_FUNC str_method_casefold
    push rbx
    push r12
    push r13

    mov rbx, [rdi]
    mov r12, [rbx + PyStrObject.ob_size]

    lea rdi, [rbx + PyStrObject.data]
    mov rsi, r12
    call str_new_heap
    mov r13, rax

    xor ecx, ecx
.cf_loop:
    cmp rcx, r12
    jge .cf_done
    movzx eax, byte [r13 + PyStrObject.data + rcx]
    cmp al, 'A'
    jb .cf_next
    cmp al, 'Z'
    ja .cf_next
    add al, 32
    mov [r13 + PyStrObject.data + rcx], al
.cf_next:
    inc rcx
    jmp .cf_loop
.cf_done:
    mov rax, r13
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC str_method_casefold

;; ============================================================================
;; str_method_center(args, nargs) -> new centered string
;; args[0]=self, args[1]=width, args[2]=fillchar (optional, default ' ')
;; ============================================================================
PA_SELF   equ 8
PA_LEN    equ 16
PA_ARGS   equ 24
PA_NARGS  equ 32
PA_FRAME  equ 32
DEF_FUNC str_method_center, PA_FRAME
    push rbx
    push r12
    push r13

    mov [rbp - PA_ARGS], rdi
    mov [rbp - PA_NARGS], rsi
    mov rbx, [rdi]                      ; self
    mov r12, [rbx + PyStrObject.ob_size]; self_len
    mov [rbp - PA_SELF], rbx
    mov [rbp - PA_LEN], r12

    ; Get width
    mov rdi, [rbp - PA_ARGS]
    mov rax, rdi
    mov rdi, [rax + 16]                 ; args[1] payload
    mov edx, [rax + 24]                 ; args[1] tag
    call int_to_i64
    mov r13, rax                         ; r13 = width

    ; Get fillchar (default ' ')
    mov ecx, ' '
    cmp qword [rbp - PA_NARGS], 3
    jl .center_have_fill
    mov rax, [rbp - PA_ARGS]
    mov rdx, [rax + 32]                 ; args[2] payload (char str)
    movzx ecx, byte [rdx + PyStrObject.data]
.center_have_fill:
    ; If width <= self_len, return copy of self
    cmp r13, r12
    jle .center_return_self

    ; Allocate new string of size width
    mov rdi, r13
    push rcx                             ; save fillchar
    call ap_malloc
    pop rcx
    mov rbx, rax                         ; rbx = new string buffer (raw)
    ; Fill entire buffer with fillchar
    push rcx
    mov rdi, rbx
    movzx esi, cl
    mov rdx, r13
    call ap_memset
    pop rcx

    ; Now create proper str object: str_new_heap(data, len)
    mov rdi, rbx
    mov rsi, r13
    call str_new_heap
    push rax                             ; save new str

    ; Free temp buffer
    mov rdi, rbx
    call ap_free
    pop r13                              ; r13 = new str

    ; Copy self data into center position
    mov rbx, [rbp - PA_SELF]
    mov r12, [rbp - PA_LEN]
    mov rax, [rbp - PA_LEN]
    mov rcx, [r13 + PyStrObject.ob_size]
    sub rcx, rax                         ; pad = width - len
    shr rcx, 1                           ; left_pad = pad / 2
    lea rdi, [r13 + PyStrObject.data + rcx]
    lea rsi, [rbx + PyStrObject.data]
    mov rdx, r12
    call ap_memcpy

    mov rax, r13
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret

.center_return_self:
    ; Return copy of self
    mov rbx, [rbp - PA_SELF]
    mov r12, [rbp - PA_LEN]
    lea rdi, [rbx + PyStrObject.data]
    mov rsi, r12
    call str_new_heap
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
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
    mov rbx, [rdi]
    mov r12, [rbx + PyStrObject.ob_size]
    mov [rbp - PA_SELF], rbx
    mov [rbp - PA_LEN], r12

    ; Get width
    mov rax, [rbp - PA_ARGS]
    mov rdi, [rax + 16]
    mov edx, [rax + 24]
    call int_to_i64
    mov r13, rax

    ; Get fillchar
    mov ecx, ' '
    cmp qword [rbp - PA_NARGS], 3
    jl .ljust_have_fill
    mov rax, [rbp - PA_ARGS]
    mov rdx, [rax + 32]
    mov rax, [rax + 40]
    test rax, rax
    js .ljust_fill_ss
    movzx ecx, byte [rdx + PyStrObject.data]
    jmp .ljust_have_fill
.ljust_fill_ss:
    movzx ecx, dl
.ljust_have_fill:
    cmp r13, r12
    jle .ljust_return_self

    ; Allocate, fill, copy self at start
    mov rdi, r13
    push rcx
    call ap_malloc
    pop rcx
    mov rbx, rax
    mov rdi, rbx
    movzx esi, cl
    mov rdx, r13
    call ap_memset
    mov rdi, rbx
    mov rsi, r13
    call str_new_heap
    push rax
    mov rdi, rbx
    call ap_free
    pop r13

    ; Copy self at position 0
    mov rbx, [rbp - PA_SELF]
    mov r12, [rbp - PA_LEN]
    lea rdi, [r13 + PyStrObject.data]
    lea rsi, [rbx + PyStrObject.data]
    mov rdx, r12
    call ap_memcpy

    mov rax, r13
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret

.ljust_return_self:
    mov rbx, [rbp - PA_SELF]
    lea rdi, [rbx + PyStrObject.data]
    mov rsi, [rbp - PA_LEN]
    call str_new_heap
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
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
    mov rbx, [rdi]
    mov r12, [rbx + PyStrObject.ob_size]
    mov [rbp - PA_SELF], rbx
    mov [rbp - PA_LEN], r12

    mov rax, [rbp - PA_ARGS]
    mov rdi, [rax + 16]
    mov edx, [rax + 24]
    call int_to_i64
    mov r13, rax

    mov ecx, ' '
    cmp qword [rbp - PA_NARGS], 3
    jl .rjust_have_fill
    mov rax, [rbp - PA_ARGS]
    mov rdx, [rax + 32]
    mov rax, [rax + 40]
    test rax, rax
    js .rjust_fill_ss
    movzx ecx, byte [rdx + PyStrObject.data]
    jmp .rjust_have_fill
.rjust_fill_ss:
    movzx ecx, dl
.rjust_have_fill:
    cmp r13, r12
    jle .rjust_return_self

    mov rdi, r13
    push rcx
    call ap_malloc
    pop rcx
    mov rbx, rax
    mov rdi, rbx
    movzx esi, cl
    mov rdx, r13
    call ap_memset
    mov rdi, rbx
    mov rsi, r13
    call str_new_heap
    push rax
    mov rdi, rbx
    call ap_free
    pop r13

    ; Copy self at end (offset = width - len)
    mov rbx, [rbp - PA_SELF]
    mov r12, [rbp - PA_LEN]
    mov rcx, [r13 + PyStrObject.ob_size]
    sub rcx, r12
    lea rdi, [r13 + PyStrObject.data + rcx]
    lea rsi, [rbx + PyStrObject.data]
    mov rdx, r12
    call ap_memcpy

    mov rax, r13
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret

.rjust_return_self:
    mov rbx, [rbp - PA_SELF]
    lea rdi, [rbx + PyStrObject.data]
    mov rsi, [rbp - PA_LEN]
    call str_new_heap
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
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

    mov rax, [rbp - PA_ARGS]
    mov rdi, [rax + 16]
    mov edx, [rax + 24]
    call int_to_i64
    mov r13, rax                         ; width

    cmp r13, r12
    jle .zfill_return_self

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
    ret
END_FUNC str_method_zfill

;; ============================================================================
;; str_method_rindex(args, nargs) -> int
;; Like rfind but raises ValueError if not found
;; args[0]=self, args[1]=substr
;; ============================================================================
DEF_FUNC str_method_rindex
    push rbx
    push r12
    push r13

    mov rbx, [rdi]           ; self
    mov r12, [rdi + 16]      ; substr
    mov r13, [rbx + PyStrObject.ob_size]
    mov rcx, [r12 + PyStrObject.ob_size]

    ; Search from end: try each position from (len-sublen) down to 0
    mov rax, r13
    sub rax, rcx
    js .rindex_not_found      ; substr longer than self
.rindex_loop:
    cmp rax, 0
    jl .rindex_not_found
    push rax
    push rcx
    lea rdi, [rbx + PyStrObject.data]
    add rdi, rax
    lea rsi, [r12 + PyStrObject.data]
    mov rdx, rcx
    call ap_memcmp
    mov r8d, eax              ; save memcmp result
    pop rcx
    pop rax                   ; restore position
    test r8d, r8d
    jz .rindex_found
    dec rax
    jmp .rindex_loop

.rindex_found:
    mov rdi, rax
    call int_from_i64
    pop r13
    pop r12
    pop rbx
    leave
    ret

.rindex_not_found:
    lea rdi, [rel exc_ValueError_type]
    CSTRING rsi, "substring not found"
    call raise_exception
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC str_method_rindex

;; ============================================================================
;; str_method_istitle(args, nargs) -> bool
;; ============================================================================
DEF_FUNC str_method_istitle
    push rbx
    push r12

    mov rbx, [rdi]
    mov r12, [rbx + PyStrObject.ob_size]

    ; Empty string → False
    test r12, r12
    jz .istitle_false

    xor ecx, ecx            ; i = 0
    mov r8d, 1               ; prev_sep = true
    xor r9d, r9d             ; seen_cased = false
.istitle_loop:
    cmp rcx, r12
    jge .istitle_check
    movzx eax, byte [rbx + PyStrObject.data + rcx]
    cmp al, 'A'
    jb .istitle_not_alpha
    cmp al, 'Z'
    jbe .istitle_upper
    cmp al, 'a'
    jb .istitle_not_alpha
    cmp al, 'z'
    ja .istitle_not_alpha
    ; lowercase char
    test r8d, r8d
    jnz .istitle_false        ; lowercase after separator → not title
    xor r8d, r8d
    mov r9d, 1
    inc rcx
    jmp .istitle_loop
.istitle_upper:
    test r8d, r8d
    jz .istitle_false         ; uppercase after alpha → not title
    xor r8d, r8d
    mov r9d, 1
    inc rcx
    jmp .istitle_loop
.istitle_not_alpha:
    mov r8d, 1                ; prev_sep = true
    inc rcx
    jmp .istitle_loop
.istitle_check:
    test r9d, r9d
    jz .istitle_false         ; no cased chars → False
    lea rax, [rel bool_true]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret
.istitle_false:
    lea rax, [rel bool_false]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret
END_FUNC str_method_istitle

;; ============================================================================
;; str_method_partition(args, nargs) -> 3-tuple (before, sep, after)
;; args[0]=self, args[1]=sep
;; ============================================================================
PT_SELF   equ 8
PT_SEP    equ 16
PT_FRAME  equ 16
DEF_FUNC str_method_partition, PT_FRAME
    push rbx
    push r12
    push r13

    mov rbx, [rdi]           ; self
    mov r12, [rdi + 16]      ; sep
    mov [rbp - PT_SELF], rbx
    mov [rbp - PT_SEP], r12

    ; Find sep in self
    lea rdi, [rbx + PyStrObject.data]
    lea rsi, [r12 + PyStrObject.data]
    call ap_strstr
    test rax, rax
    jz .part_not_found

    ; Found: compute before, sep, after
    mov r13, rax             ; pointer to match
    lea rcx, [rbx + PyStrObject.data]
    sub r13, rcx             ; r13 = match index

    ; Create before string
    lea rdi, [rbx + PyStrObject.data]
    mov rsi, r13
    call str_new_heap
    push rax                 ; save before

    ; INCREF sep (reuse original)
    mov r12, [rbp - PT_SEP]
    INCREF r12

    ; Create after string
    mov rbx, [rbp - PT_SELF]
    mov rcx, [r12 + PyStrObject.ob_size]
    lea rax, [r13 + rcx]     ; after_start = match_idx + sep_len
    mov rdx, [rbx + PyStrObject.ob_size]
    sub rdx, rax              ; after_len = self_len - after_start
    lea rdi, [rbx + PyStrObject.data + rax]
    mov rsi, rdx
    call str_new_heap
    mov r13, rax             ; r13 = after

    ; Create 3-tuple
    mov rdi, 3
    call tuple_new
    mov rbx, rax             ; rbx = tuple

    mov r9, [rbx + PyTupleObject.ob_item]
    mov r10, [rbx + PyTupleObject.ob_item_tags]
    pop rcx                  ; before
    mov [r9], rcx
    mov byte [r10], TAG_PTR
    mov [r9 + 8], r12
    mov byte [r10 + 1], TAG_PTR
    mov [r9 + 16], r13
    mov byte [r10 + 2], TAG_PTR

    mov rax, rbx
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret

.part_not_found:
    ; Return (self_copy, "", "")
    mov rbx, [rbp - PT_SELF]
    lea rdi, [rbx + PyStrObject.data]
    mov rsi, [rbx + PyStrObject.ob_size]
    call str_new_heap
    push rax                 ; before = self copy

    ; Create two empty strings
    CSTRING rdi, ""
    xor esi, esi
    call str_new_heap
    push rax                 ; empty1

    CSTRING rdi, ""
    xor esi, esi
    call str_new_heap
    mov r13, rax             ; empty2

    mov rdi, 3
    call tuple_new
    mov rbx, rax

    mov r9, [rbx + PyTupleObject.ob_item]
    mov r10, [rbx + PyTupleObject.ob_item_tags]
    pop rcx                  ; empty1
    pop rax                  ; before
    mov [r9], rax
    mov byte [r10], TAG_PTR
    mov [r9 + 8], rcx
    mov byte [r10 + 1], TAG_PTR
    mov [r9 + 16], r13
    mov byte [r10 + 2], TAG_PTR

    mov rax, rbx
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC str_method_partition

;; ============================================================================
;; str_method_rpartition(args, nargs) -> 3-tuple (before, sep, after)
;; Like partition but searches from right
;; ============================================================================
DEF_FUNC str_method_rpartition, PT_FRAME
    push rbx
    push r12
    push r13

    mov rbx, [rdi]           ; self
    mov r12, [rdi + 16]      ; sep
    mov [rbp - PT_SELF], rbx
    mov [rbp - PT_SEP], r12

    ; Search from right: find last occurrence
    mov r13, [rbx + PyStrObject.ob_size]
    mov rcx, [r12 + PyStrObject.ob_size]
    mov rax, r13
    sub rax, rcx              ; max start pos
    js .rpart_not_found

.rpart_loop:
    cmp rax, 0
    jl .rpart_not_found
    push rax
    push rcx
    lea rdi, [rbx + PyStrObject.data]
    add rdi, rax
    lea rsi, [r12 + PyStrObject.data]
    mov rdx, rcx
    call ap_memcmp
    mov r8d, eax              ; save memcmp result
    pop rcx
    pop rax
    test r8d, r8d
    jz .rpart_found
    dec rax
    jmp .rpart_loop

.rpart_found:
    ; rax = match index
    mov r13, rax

    ; Create before string
    lea rdi, [rbx + PyStrObject.data]
    mov rsi, r13
    call str_new_heap
    push rax

    ; INCREF sep
    mov r12, [rbp - PT_SEP]
    INCREF r12

    ; Create after string
    mov rbx, [rbp - PT_SELF]
    mov rcx, [r12 + PyStrObject.ob_size]
    lea rax, [r13 + rcx]
    mov rdx, [rbx + PyStrObject.ob_size]
    sub rdx, rax
    lea rdi, [rbx + PyStrObject.data + rax]
    mov rsi, rdx
    call str_new_heap
    mov r13, rax

    mov rdi, 3
    call tuple_new
    mov rbx, rax

    mov r9, [rbx + PyTupleObject.ob_item]
    mov r10, [rbx + PyTupleObject.ob_item_tags]
    pop rcx
    mov [r9], rcx
    mov byte [r10], TAG_PTR
    mov [r9 + 8], r12
    mov byte [r10 + 1], TAG_PTR
    mov [r9 + 16], r13
    mov byte [r10 + 2], TAG_PTR

    mov rax, rbx
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret

.rpart_not_found:
    ; Return ("", "", self_copy)
    CSTRING rdi, ""
    xor esi, esi
    call str_new_heap
    push rax

    CSTRING rdi, ""
    xor esi, esi
    call str_new_heap
    push rax

    mov rbx, [rbp - PT_SELF]
    lea rdi, [rbx + PyStrObject.data]
    mov rsi, [rbx + PyStrObject.ob_size]
    call str_new_heap
    mov r13, rax

    mov rdi, 3
    call tuple_new
    mov rbx, rax

    mov r9, [rbx + PyTupleObject.ob_item]
    mov r10, [rbx + PyTupleObject.ob_item_tags]
    pop rcx                  ; empty2
    pop rax                  ; empty1
    mov [r9], rax
    mov byte [r10], TAG_PTR
    mov [r9 + 8], rcx
    mov byte [r10 + 1], TAG_PTR
    mov [r9 + 16], r13
    mov byte [r10 + 2], TAG_PTR

    mov rax, rbx
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC str_method_rpartition

;; ============================================================================
;; str_method_expandtabs(args, nargs) -> new string
;; args[0]=self, args[1]=tabsize (optional, default 8)
;; ============================================================================
ET_TAB    equ 8
ET_BUF    equ 16
ET_RES    equ 24
ET_FRAME  equ 32
DEF_FUNC str_method_expandtabs, ET_FRAME
    push rbx
    push r12
    push r13
    push r14

    mov rbx, [rdi]           ; self
    mov r12, [rbx + PyStrObject.ob_size]

    ; Get tabsize (default 8)
    mov r13, 8
    cmp rsi, 2
    jl .et_have_tab
    mov rax, rdi
    mov rdi, [rax + 16]
    mov edx, [rax + 24]
    call int_to_i64
    mov r13, rax
.et_have_tab:
    mov [rbp - ET_TAB], r13

    ; First pass: compute output length
    xor ecx, ecx            ; i
    xor r14d, r14d           ; col
    xor r8d, r8d             ; out_len
.et_len_loop:
    cmp rcx, r12
    jge .et_len_done
    movzx eax, byte [rbx + PyStrObject.data + rcx]
    cmp al, 9                ; '\t'
    je .et_len_tab
    cmp al, 10               ; '\n'
    je .et_len_nl
    cmp al, 13               ; '\r'
    je .et_len_nl
    inc r14                  ; col++
    inc r8                   ; out_len++
    inc rcx
    jmp .et_len_loop
.et_len_tab:
    ; spaces = tabsize - (col % tabsize)
    test r13, r13
    jz .et_len_tab_zero
    mov rax, r14
    xor edx, edx
    div r13                  ; rdx = col % tabsize
    mov rax, r13
    sub rax, rdx             ; spaces
    add r8, rax
    add r14, rax
    inc rcx
    jmp .et_len_loop
.et_len_tab_zero:
    inc rcx
    jmp .et_len_loop
.et_len_nl:
    inc r8
    xor r14d, r14d           ; reset col
    inc rcx
    jmp .et_len_loop
.et_len_done:

    ; Allocate output buffer
    mov rdi, r8
    call ap_malloc
    mov [rbp - ET_BUF], rax
    mov r9, rax              ; r9 = output buffer

    ; Second pass: fill output
    mov r13, [rbp - ET_TAB]
    xor ecx, ecx            ; i (input)
    xor r14d, r14d           ; col
    xor r8d, r8d             ; j (output)
.et_fill_loop:
    cmp rcx, r12
    jge .et_fill_done
    movzx eax, byte [rbx + PyStrObject.data + rcx]
    cmp al, 9
    je .et_fill_tab
    cmp al, 10
    je .et_fill_nl
    cmp al, 13
    je .et_fill_nl
    mov [r9 + r8], al
    inc r14
    inc r8
    inc rcx
    jmp .et_fill_loop
.et_fill_tab:
    test r13, r13
    jz .et_fill_tab_skip
    mov rax, r14
    xor edx, edx
    div r13
    mov rax, r13
    sub rax, rdx             ; spaces
    ; Fill spaces
    mov r10, rax
.et_fill_spaces:
    test r10, r10
    jz .et_fill_tab_skip
    mov byte [r9 + r8], ' '
    inc r8
    inc r14
    dec r10
    jmp .et_fill_spaces
.et_fill_tab_skip:
    inc rcx
    jmp .et_fill_loop
.et_fill_nl:
    mov [r9 + r8], al
    inc r8
    xor r14d, r14d
    inc rcx
    jmp .et_fill_loop
.et_fill_done:
    ; Create str from buffer
    mov rdi, [rbp - ET_BUF]
    mov rsi, r8
    call str_new_heap
    mov [rbp - ET_RES], rax

    ; Free temp buffer
    mov rdi, [rbp - ET_BUF]
    call ap_free

    mov rax, [rbp - ET_RES]
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC str_method_expandtabs

;; ============================================================================
;; str_method_splitlines(args, nargs) -> list of lines
;; args[0]=self, args[1]=keepends (optional bool, default False)
;; ============================================================================
DEF_FUNC str_method_splitlines
    push rbx
    push r12
    push r13
    push r14

    mov rbx, [rdi]           ; self
    mov r12, [rbx + PyStrObject.ob_size]

    ; Get keepends flag
    xor r14d, r14d           ; default: don't keep
    cmp rsi, 2
    jl .sl_have_keep
    ; Check args[1] - bool_true means keep
    lea rax, [rel bool_true]
    cmp qword [rdi + 16], rax
    sete r14b
.sl_have_keep:

    ; Create result list
    xor edi, edi
    call list_new
    mov r13, rax             ; result list

    ; Scan for line breaks
    xor ecx, ecx            ; i = start of current line
    xor r8d, r8d             ; j = scanner
.sl_loop:
    cmp r8, r12
    jge .sl_last

    movzx eax, byte [rbx + PyStrObject.data + r8]
    cmp al, 10               ; '\n'
    je .sl_found
    cmp al, 13               ; '\r'
    je .sl_found_cr
    inc r8
    jmp .sl_loop

.sl_found_cr:
    ; Check for \r\n
    lea rax, [r8 + 1]
    cmp rax, r12
    jge .sl_found            ; no more chars after \r
    movzx eax, byte [rbx + PyStrObject.data + rax]
    cmp al, 10
    jne .sl_found            ; not \r\n, just \r
    ; \r\n: end_pos = r8 + 2
    test r14d, r14d
    jz .sl_no_keep_crlf
    ; keepends: include \r\n
    lea rdx, [r8 + 2]
    sub rdx, rcx
    jmp .sl_emit_line
.sl_no_keep_crlf:
    mov rdx, r8
    sub rdx, rcx
    push rcx
    push r8
    lea rdi, [rbx + PyStrObject.data + rcx]
    mov rsi, rdx
    call str_new_heap
    push rax
    mov rdi, r13
    mov rsi, rax
    call list_append
    pop rdi
    call obj_decref
    pop r8
    pop rcx
    lea rcx, [r8 + 2]        ; skip \r\n
    lea r8, [r8 + 2]
    jmp .sl_loop

.sl_found:
    ; Line break at r8
    test r14d, r14d
    jz .sl_no_keep
    ; keepends: include the newline char
    lea rdx, [r8 + 1]
    sub rdx, rcx
    jmp .sl_emit_line
.sl_no_keep:
    mov rdx, r8
    sub rdx, rcx
.sl_emit_line:
    push rcx
    push r8
    lea rdi, [rbx + PyStrObject.data + rcx]
    mov rsi, rdx
    call str_new_heap
    push rax
    mov rdi, r13
    mov rsi, rax
    call list_append
    pop rdi
    call obj_decref
    pop r8
    pop rcx
    lea rcx, [r8 + 1]
    lea r8, [r8 + 1]
    jmp .sl_loop

.sl_last:
    ; Remaining text after last newline
    cmp rcx, r12
    jge .sl_done
    mov rdx, r12
    sub rdx, rcx
    lea rdi, [rbx + PyStrObject.data + rcx]
    mov rsi, rdx
    call str_new_heap
    push rax
    mov rdi, r13
    mov rsi, rax
    call list_append
    pop rdi
    call obj_decref

.sl_done:
    mov rax, r13
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC str_method_splitlines

;; ============================================================================
;; str_method_rsplit(args, nargs) -> list
;; Like split but from right. args[0]=self, args[1]=sep (optional)
;; For simplicity, implements same as split (no maxsplit from right)
;; ============================================================================
DEF_FUNC_BARE str_method_rsplit
    ; Delegate to split for now (rsplit without maxsplit = split)
    jmp str_method_split
END_FUNC str_method_rsplit

;; ============================================================================
;; str_method_translate(args, nargs) -> new string
;; args[0]=self, args[1]=table (dict mapping ordinals to ordinals/strings/None)
;; ============================================================================
DEF_FUNC str_method_translate
    push rbx
    push r12
    push r13
    push r14

    mov rbx, [rdi]           ; self
    mov r12, [rbx + PyStrObject.ob_size]
    mov r14, [rdi + 16]      ; table (dict)

    ; Build result: for each char, look up ord(char) in table
    xor edi, edi
    call list_new
    mov r13, rax             ; result list (of chars/strings)

    xor ecx, ecx
.tr_loop:
    cmp rcx, r12
    jge .tr_join

    ; Get ordinal of current char
    movzx eax, byte [rbx + PyStrObject.data + rcx]
    push rcx

    ; Look up in table: dict_get(table, ord_key)
    ; Create SmallInt key
    movzx edi, al
    call int_from_i64
    ; rax = SmallInt payload, edx = TAG_SMALLINT
    push rax
    push rdx
    mov rdi, r14
    mov rsi, rax
    mov edx, edx
    call dict_get
    pop r8                   ; original key tag
    pop r9                   ; original key payload
    test edx, edx
    jz .tr_not_found

    ; Found: check what the value is
    ; If None: skip char (delete)
    lea rcx, [rel none_singleton]
    cmp rax, rcx
    je .tr_delete

    ; If SmallInt: character ordinal
    cmp edx, TAG_SMALLINT
    je .tr_ord

    ; Else: it's a string, append it
    push rax
    mov rdi, r13
    mov rsi, rax
    call list_append
    pop rdi
    call obj_decref
    pop rcx
    inc rcx
    jmp .tr_loop

.tr_ord:
    ; Convert ordinal to 1-char string
    push rax
    sub rsp, 8
    mov [rsp], al
    mov byte [rsp + 1], 0
    mov rdi, rsp
    mov rsi, 1
    call str_new_heap
    add rsp, 8
    push rax
    mov rdi, r13
    mov rsi, rax
    call list_append
    pop rdi
    call obj_decref
    pop rax                  ; discard saved ordinal
    pop rcx
    inc rcx
    jmp .tr_loop

.tr_not_found:
    ; Not in table: keep original char
    movzx eax, byte [rbx + PyStrObject.data + rcx]  ; rcx is on stack
    ; Wait, rcx was pushed. Let me get it from stack.
    mov rcx, [rsp]           ; peek at saved rcx
    movzx eax, byte [rbx + PyStrObject.data + rcx]
    sub rsp, 8
    mov [rsp], al
    mov byte [rsp + 1], 0
    mov rdi, rsp
    mov rsi, 1
    call str_new_heap
    add rsp, 8
    push rax
    mov rdi, r13
    mov rsi, rax
    call list_append
    pop rdi
    call obj_decref
    pop rcx
    inc rcx
    jmp .tr_loop

.tr_delete:
    ; Skip this character (mapped to None)
    pop rcx
    inc rcx
    jmp .tr_loop

.tr_join:
    ; Join all pieces: "".join(result_list)
    CSTRING rdi, ""
    xor esi, esi
    call str_new_heap
    push rax                 ; empty sep

    ; Build args for join: [sep, list]
    sub rsp, 32
    mov rax, [rsp + 32]     ; sep
    mov [rsp], rax
    mov qword [rsp + 8], TAG_PTR
    mov [rsp + 16], r13
    mov qword [rsp + 24], TAG_PTR
    mov rdi, rsp
    mov rsi, 2
    call str_method_join
    add rsp, 32
    push rax
    push rdx

    ; Cleanup: DECREF sep and list
    mov rdi, [rsp + 16]     ; sep
    call obj_decref
    mov rdi, r13
    call obj_decref

    pop rdx
    pop rax
    add rsp, 8              ; sep ptr

    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC str_method_translate

;; ============================================================================
;; str_staticmethod_maketrans(args, nargs) -> dict
;; 2-arg form: maketrans(x, y) where x and y are strings of equal length
;; Returns dict mapping ord(x[i]) -> ord(y[i])
;; Note: called as staticmethod, so no 'self' arg.
;; ============================================================================
SMT_FROM  equ 8
SMT_TO    equ 16
SMT_FRAME equ 24

DEF_FUNC str_staticmethod_maketrans, SMT_FRAME
    push rbx
    push r12
    push r13

    cmp rsi, 2
    jne .smt_error

    ; Get from and to strings
    mov rcx, [rdi]                 ; args[0] payload (from str)
    mov [rbp - SMT_FROM], rcx

    mov rcx, [rdi + 16]            ; args[1] payload (to str)
    mov [rbp - SMT_TO], rcx

    ; Check equal lengths
    mov rax, [rbp - SMT_FROM]
    mov rcx, [rbp - SMT_TO]
    mov r12, [rax + PyStrObject.ob_size]
    cmp r12, [rcx + PyStrObject.ob_size]
    jne .smt_len_error

    ; Create result dict
    call dict_new
    mov rbx, rax                    ; result dict

    ; For each character position, map ord(from[i]) -> ord(to[i])
    xor r13d, r13d                  ; index
.smt_loop:
    cmp r13, r12
    jge .smt_done

    ; Get from char ordinal
    mov rax, [rbp - SMT_FROM]
    movzx edi, byte [rax + PyStrObject.data + r13]
    ; Get to char ordinal
    mov rax, [rbp - SMT_TO]
    movzx esi, byte [rax + PyStrObject.data + r13]

    ; dict_set(dict, key=ord_from, value=ord_to, value_tag=SMALLINT, key_tag=SMALLINT)
    push r13
    mov rdi, rbx                    ; dict
    ; rsi already = to ordinal (value becomes SmallInt)
    mov rdx, rsi                    ; value = to ordinal
    movzx esi, byte [rax + PyStrObject.data + r13] ; recalc — but we need from ordinal as key
    ; Actually: rdi=dict, rsi=key, rdx=value, rcx=value_tag, r8=key_tag
    mov rcx, [rbp - SMT_FROM]
    movzx esi, byte [rcx + PyStrObject.data + r13]  ; key = from ordinal
    mov rax, [rbp - SMT_TO]
    movzx edx, byte [rax + PyStrObject.data + r13]  ; value = to ordinal
    mov ecx, TAG_SMALLINT           ; value_tag
    mov r8d, TAG_SMALLINT           ; key_tag
    call dict_set
    pop r13

    inc r13
    jmp .smt_loop

.smt_done:
    mov rax, rbx
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret

.smt_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "maketrans requires 2 string arguments"
    call raise_exception

.smt_len_error:
    lea rdi, [rel exc_ValueError_type]
    CSTRING rsi, "maketrans arguments must have equal length"
    call raise_exception
END_FUNC str_staticmethod_maketrans

;; args[0]=self, args[1]=prefix
;; If self starts with prefix, return self[len(prefix):], else return self.
;; ============================================================================
DEF_FUNC str_method_removeprefix
    push rbx
    push r12
    push r13
    push r14

    ; Validate args[1] is a string
    mov rax, [rdi + 24]        ; args[1] tag
    cmp eax, TAG_PTR
    jne .rp_type_error
    mov rax, [rdi + 16]
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    jne .rp_type_error

    mov rbx, [rdi]          ; self
    mov r12, [rdi + 16]     ; prefix
    mov r13, [rbx + PyStrObject.ob_size]   ; self len
    mov r14, [r12 + PyStrObject.ob_size]   ; prefix len

    ; If prefix longer than self, return self (INCREF)
    cmp r14, r13
    jg .rmpfx_return_self

    ; Compare first prefix_len bytes
    xor ecx, ecx
.rmpfx_cmp:
    cmp rcx, r14
    jge .rmpfx_match
    movzx eax, byte [rbx + PyStrObject.data + rcx]
    cmp al, [r12 + PyStrObject.data + rcx]
    jne .rmpfx_return_self
    inc rcx
    jmp .rmpfx_cmp

.rmpfx_match:
    ; Prefix matches - return str_new(data+preflen, len-preflen)
    lea rdi, [rbx + PyStrObject.data]
    add rdi, r14
    mov rsi, r13
    sub rsi, r14
    call str_new_heap
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.rmpfx_return_self:
    mov rax, rbx
    INCREF rax
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.rp_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "must be str, not other type"
    call raise_exception
END_FUNC str_method_removeprefix

;; ============================================================================
;; str_method_removesuffix(args, nargs) -> new string
;; args[0]=self, args[1]=suffix
;; If self ends with suffix, return self[:len(self)-len(suffix)], else return self.
;; ============================================================================
DEF_FUNC str_method_removesuffix
    push rbx
    push r12
    push r13
    push r14

    ; Validate args[1] is a string
    mov rax, [rdi + 24]        ; args[1] tag
    cmp eax, TAG_PTR
    jne .rs_type_error
    mov rax, [rdi + 16]
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    jne .rs_type_error

    mov rbx, [rdi]          ; self
    mov r12, [rdi + 16]     ; suffix
    mov r13, [rbx + PyStrObject.ob_size]   ; self len
    mov r14, [r12 + PyStrObject.ob_size]   ; suffix len

    ; If suffix longer than self, return self (INCREF)
    cmp r14, r13
    jg .rmsfx_return_self

    ; If suffix is empty, return self (INCREF)
    test r14, r14
    jz .rmsfx_return_self

    ; Compare last suffix_len bytes of self with suffix
    mov rcx, r13
    sub rcx, r14            ; offset = self_len - suffix_len
    xor edx, edx
.rmsfx_cmp:
    cmp rdx, r14
    jge .rmsfx_match
    movzx eax, byte [rbx + PyStrObject.data + rcx]
    cmp al, [r12 + PyStrObject.data + rdx]
    jne .rmsfx_return_self
    inc rcx
    inc rdx
    jmp .rmsfx_cmp

.rmsfx_match:
    ; Suffix matches - return str_new(data, len-suffixlen)
    lea rdi, [rbx + PyStrObject.data]
    mov rsi, r13
    sub rsi, r14
    call str_new_heap
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.rmsfx_return_self:
    mov rax, rbx
    INCREF rax
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.rs_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "must be str, not other type"
    call raise_exception
END_FUNC str_method_removesuffix

;; ============================================================================
;; str_method_encode(args, nargs) -> bytes
;; args[0]=self, args[1]=encoding (optional, default 'utf-8')
;; For now, supports 'utf-8' and 'ascii' — both just copy raw bytes.
;; ============================================================================
DEF_FUNC str_method_encode
    push rbx
    push r12
    ; args[0] = self (str)
    mov rbx, [rdi]             ; rbx = self str obj
    mov r12, [rbx + PyStrObject.ob_size]  ; r12 = length
    ; Allocate bytes object
    mov rdi, r12
    extern bytes_new
    call bytes_new
    ; Copy string data into bytes object
    lea rdi, [rax + PyBytesObject.data]
    lea rsi, [rbx + PyStrObject.data]
    mov rdx, r12
    push rax                   ; save bytes obj
    extern ap_memcpy
    call ap_memcpy
    pop rax                    ; return bytes obj
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret
END_FUNC str_method_encode


;; ############################################################################
;;                         LIST METHODS
;; ############################################################################

;; ============================================================================
;; list_method_append(args, nargs) -> None
;; args[0]=self, args[1]=item
;; ============================================================================
DEF_FUNC list_method_append

    mov rax, [rdi]          ; self (list)
    ; Check if list is being sorted (ob_item == NULL)
    cmp qword [rax + PyListObject.ob_item], 0
    je list_sorting_error
    mov rsi, [rdi + 16]     ; item payload
    mov rdx, [rdi + 24]     ; item tag (16-byte stride)
    mov rdi, rax
    call list_append

    lea rax, [rel none_singleton]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    ret
END_FUNC list_method_append

;; ============================================================================
;; list_method_pop(args, nargs) -> removed item
;; args[0]=self, optionally args[1]=index (default: last)
;; ============================================================================
DEF_FUNC list_method_pop
    push rbx
    push r12
    push r13

    mov rax, rdi            ; rax = args ptr
    mov rbx, [rax]          ; self (list)
    ; Check if list is being sorted (ob_item == NULL)
    cmp qword [rbx + PyListObject.ob_item], 0
    je list_sorting_error
    mov r12, rsi            ; nargs

    ; Get index
    cmp r12, 2
    jge .pop_idx
    ; Default: pop last element
    mov r13, [rbx + PyListObject.ob_size]
    dec r13                 ; index = size - 1
    jmp .pop_do

.pop_idx:
    mov rdi, [rax + 16]    ; args[1]
    mov rdx, [rax + 24]    ; args[1] tag
    call int_to_i64
    mov r13, rax

    ; Handle negative index
    test r13, r13
    jns .pop_do
    add r13, [rbx + PyListObject.ob_size]

.pop_do:
    ; Bounds check
    cmp r13, 0
    jl .pop_error
    cmp r13, [rbx + PyListObject.ob_size]
    jge .pop_error

    ; Get the item (it already has refs from being in the list)
    mov rax, [rbx + PyListObject.ob_item]
    mov rcx, [rbx + PyListObject.ob_item_tags]
    mov r12, [rax + r13 * 8]        ; payload to return
    movzx edx, byte [rcx + r13]     ; tag to return
    push rdx                        ; save tag on stack
    ; Don't DECREF since we're transferring ownership to caller

    ; Shift payloads down: memmove(&payloads[idx], &payloads[idx+1], (size-1-idx)*8)
    mov rax, [rbx + PyListObject.ob_item]
    lea rdi, [rax + r13 * 8]        ; dst = &payloads[idx]
    lea rsi, [rdi + 8]              ; src = &payloads[idx+1]
    mov rdx, [rbx + PyListObject.ob_size]
    sub rdx, r13
    dec rdx                         ; count = size - idx - 1
    shl rdx, 3                      ; bytes = count * 8
    jz .pop_shift_tags              ; nothing to shift if popping last
    call ap_memmove

.pop_shift_tags:
    ; Shift tags down: memmove(&tags[idx], &tags[idx+1], count)
    mov rax, [rbx + PyListObject.ob_item_tags]
    lea rdi, [rax + r13]
    lea rsi, [rdi + 1]
    mov rdx, [rbx + PyListObject.ob_size]
    sub rdx, r13
    dec rdx
    jz .pop_shrink
    call ap_memmove

.pop_shrink:
    dec qword [rbx + PyListObject.ob_size]

    ; Return item (ownership transferred, no extra INCREF needed)
    mov rax, r12
    pop rdx                  ; item tag
    pop r13
    pop r12
    pop rbx
    leave
    ret

.pop_error:
    lea rdi, [rel exc_IndexError_type]
    CSTRING rsi, "pop index out of range"
    call raise_exception
END_FUNC list_method_pop

;; ============================================================================
;; list_method_insert(args, nargs) -> None
;; args[0]=self, args[1]=index, args[2]=item
;; ============================================================================
DEF_FUNC list_method_insert
    push rbx
    push r12
    push r13
    push r14

    mov rax, rdi            ; args (16-byte stride)
    mov rbx, [rax]          ; self = args[0]
    ; Check if list is being sorted (ob_item == NULL)
    cmp qword [rbx + PyListObject.ob_item], 0
    je list_sorting_error
    push rax

    ; Get index
    mov rdi, [rax + 16]     ; args[1] payload (16B stride)
    mov rdx, [rax + 24]     ; args[1] tag
    call int_to_i64
    mov r12, rax            ; index

    pop rax
    mov r13, [rax + 32]     ; item = args[2] payload (16B stride)
    mov r14, [rax + 40]     ; item tag = args[2] tag

    ; Clamp index to [0, size]
    test r12, r12
    jns .ins_pos
    add r12, [rbx + PyListObject.ob_size]
    test r12, r12
    jns .ins_pos
    xor r12d, r12d
.ins_pos:
    cmp r12, [rbx + PyListObject.ob_size]
    jle .ins_ok
    mov r12, [rbx + PyListObject.ob_size]
.ins_ok:

    ; First append a dummy to grow the list if needed
    ; (reuse list_append logic for growth, then shift)
    ; Actually, let's just handle growth manually:
    ; Check if size == allocated
    mov rax, [rbx + PyListObject.ob_size]
    cmp rax, [rbx + PyListObject.allocated]
    jl .ins_no_grow
    ; Double capacity
    mov rdi, [rbx + PyListObject.allocated]
    shl rdi, 1
    mov [rbx + PyListObject.allocated], rdi
    mov rdi, [rbx + PyListObject.ob_item]
    mov rsi, [rbx + PyListObject.allocated]
    shl rsi, 3              ; new_cap * 8
    call ap_realloc
    mov [rbx + PyListObject.ob_item], rax
    mov rdi, [rbx + PyListObject.ob_item_tags]
    mov rsi, [rbx + PyListObject.allocated]
    call ap_realloc
    mov [rbx + PyListObject.ob_item_tags], rax
.ins_no_grow:

    ; Shift payloads up: memmove(&payloads[idx+1], &payloads[idx], (size-idx)*8)
    mov rax, [rbx + PyListObject.ob_item]
    mov rcx, r12
    shl rcx, 3              ; idx * 8
    lea rsi, [rax + rcx]    ; src = &payloads[idx]
    lea rdi, [rsi + 8]      ; dst = &payloads[idx+1]
    mov rdx, [rbx + PyListObject.ob_size]
    sub rdx, r12            ; count = size - idx
    shl rdx, 3              ; bytes = count * 8
    jz .ins_shift_tags      ; nothing to shift if inserting at end
    call ap_memmove

.ins_shift_tags:
    ; Shift tags up: memmove(&tags[idx+1], &tags[idx], count)
    mov rax, [rbx + PyListObject.ob_item_tags]
    lea rsi, [rax + r12]
    lea rdi, [rsi + 1]
    mov rdx, [rbx + PyListObject.ob_size]
    sub rdx, r12            ; count = size - idx
    jz .ins_place
    call ap_memmove

.ins_place:
    ; Place item at index
    mov rax, [rbx + PyListObject.ob_item]
    mov [rax + r12 * 8], r13    ; payload
    mov rax, [rbx + PyListObject.ob_item_tags]
    mov byte [rax + r12], r14b  ; tag
    INCREF_VAL r13, r14
    inc qword [rbx + PyListObject.ob_size]

    lea rax, [rel none_singleton]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC list_method_insert

;; ============================================================================
;; list_method_reverse(args, nargs) -> None
;; args[0]=self, reverse in place
;; ============================================================================
DEF_FUNC list_method_reverse
    push rbx
    mov rax, [rdi]          ; self
    ; Check if list is being sorted (ob_item == NULL)
    cmp qword [rax + PyListObject.ob_item], 0
    je list_sorting_error
    mov rcx, [rax + PyListObject.ob_size]
    test rcx, rcx
    jz .rev_done

    mov rdi, [rax + PyListObject.ob_item]       ; payloads
    mov rbx, [rax + PyListObject.ob_item_tags]  ; tags
    xor esi, esi            ; lo = 0
    dec rcx                 ; hi = size - 1
.rev_loop:
    cmp rsi, rcx
    jge .rev_done
    ; Swap payloads
    mov r8, [rdi + rsi * 8]      ; lo payload
    mov r10, [rdi + rcx * 8]     ; hi payload
    mov [rdi + rsi * 8], r10
    mov [rdi + rcx * 8], r8
    ; Swap tags
    movzx r9d, byte [rbx + rsi]
    movzx r11d, byte [rbx + rcx]
    mov byte [rbx + rsi], r11b
    mov byte [rbx + rcx], r9b
    inc rsi
    dec rcx
    jmp .rev_loop

.rev_done:
    lea rax, [rel none_singleton]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    pop rbx
    leave
    ret
END_FUNC list_method_reverse

;; ============================================================================
;; list_method_sort(args, nargs) -> None
;; Stable bottom-up merge sort with key= and reverse= support
;; args[0]=self
;; ============================================================================
LS_LIST    equ 8      ; list object ptr
LS_N       equ 16     ; element count
LS_SRC     equ 24     ; current source array (items or temp)
LS_DST     equ 32     ; current dest array (temp or items)
LS_TEMP    equ 40     ; temp array (for freeing)
LS_REV     equ 48     ; reverse flag (0=normal, 1=reverse)
LS_KEY     equ 56     ; key function payload (0=none)
LS_KSRC    equ 64     ; keys source array (swapped during sort)
LS_KDST    equ 72     ; keys dest array (swapped during sort)
LS_KTEMP   equ 80     ; keys temp array (2nd alloc, for freeing)
LS_KORIG   equ 168    ; original keys array (1st alloc, for freeing)
LS_WIDTH   equ 88     ; current merge width
LS_OUTI    equ 96     ; outer loop index
LS_MI      equ 104    ; merge: left index
LS_MJ      equ 112    ; merge: right index (j)
LS_MMID    equ 120    ; merge: mid boundary
LS_MREND   equ 128    ; merge: right end boundary
LS_MK      equ 136    ; merge: dest index (k)
LS_SAVED_ITEMS equ 144  ; saved fat items buffer
LS_SAVED_SIZE  equ 152  ; saved ob_size before sort
LS_SAVED_PAYLOADS equ 176 ; saved payload array ptr
LS_SAVED_TAGS     equ 184 ; saved tag array ptr
LS_FRAME   equ 192     ; includes saved payload/tag pointers
DEF_FUNC list_method_sort, LS_FRAME
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rbx, [rdi]              ; self (list)
    mov r12, [rbx + PyListObject.ob_size]
    mov [rbp - LS_LIST], rbx
    mov [rbp - LS_N], r12
    mov qword [rbp - LS_REV], 0
    mov qword [rbp - LS_KEY], 0
    mov qword [rbp - LS_KSRC], 0
    mov qword [rbp - LS_KDST], 0
    mov qword [rbp - LS_KTEMP], 0
    mov qword [rbp - LS_KORIG], 0

    ; --- Parse keyword arguments ---
    extern kw_names_pending
    extern ap_strcmp
    mov rax, [rel kw_names_pending]
    test rax, rax
    jz .sort_no_kw

    push rdi                       ; save args ptr
    push rsi                       ; save nargs

    mov rcx, [rax + PyTupleObject.ob_size]  ; n_kw
    mov r8, rsi
    sub r8, rcx                    ; r8 = n_pos
    xor r9d, r9d                   ; kw index

.sort_kw_loop:
    cmp r9, rcx
    jge .sort_kw_done

    ; Get kwarg name string ptr from kw_names tuple
    mov r10, r9
    mov rbx, [rax + PyTupleObject.ob_item]
    mov r10, [rbx + r10 * 8]

    ; Kwarg value offset: (n_pos + kw_idx) * 16
    mov r11, r8
    add r11, r9
    shl r11, 4

    ; --- Check "reverse" ---
    push rax
    push rcx
    push r8
    push r9
    push r11
    push rdi
    lea rdi, [r10 + PyStrObject.data]
    CSTRING rsi, "reverse"
    call ap_strcmp
    mov r10d, eax
    pop rdi
    pop r11
    pop r9
    pop r8
    pop rcx
    pop rax
    test r10d, r10d
    jnz .sort_kw_not_reverse

    ; Extract reverse value
    mov r10, [rdi + r11]           ; value payload
    mov r13, [rdi + r11 + 8]      ; value tag
    cmp r13d, TAG_BOOL
    je .sort_rev_bool
    cmp r13d, TAG_SMALLINT
    je .sort_rev_int
    ; TAG_PTR: check if bool_true
    lea r13, [rel bool_true]
    cmp r10, r13
    sete r10b
    movzx r10d, r10b
    mov [rbp - LS_REV], r10
    jmp .sort_kw_next
.sort_rev_bool:
    mov [rbp - LS_REV], r10       ; 0 or 1
    jmp .sort_kw_next
.sort_rev_int:
    test r10, r10
    setnz r10b
    movzx r10d, r10b
    mov [rbp - LS_REV], r10
    jmp .sort_kw_next

.sort_kw_not_reverse:
    ; --- Check "key" ---
    ; r10 was clobbered by strcmp result above, reload kwarg name
    mov r10, r9
    mov rbx, [rax + PyTupleObject.ob_item]
    mov r10, [rbx + r10 * 8]
    push rax
    push rcx
    push r8
    push r9
    push r11
    push rdi
    lea rdi, [r10 + PyStrObject.data]
    CSTRING rsi, "key"
    call ap_strcmp
    mov r10d, eax
    pop rdi
    pop r11
    pop r9
    pop r8
    pop rcx
    pop rax
    test r10d, r10d
    jnz .sort_kw_next              ; not "key" either, skip

    ; Extract key function value
    mov r10, [rdi + r11]           ; key payload
    mov r13, [rdi + r11 + 8]      ; key tag
    ; key=None means no key function
    cmp r13d, TAG_NONE
    je .sort_kw_next
    lea r14, [rel none_singleton]
    cmp r10, r14
    je .sort_kw_next
    mov [rbp - LS_KEY], r10
    jmp .sort_kw_next

.sort_kw_next:
    inc r9
    jmp .sort_kw_loop

.sort_kw_done:
    pop rsi
    pop rdi
    mov qword [rel kw_names_pending], 0
    mov rbx, [rbp - LS_LIST]           ; reload list (clobbered by kw parsing)

.sort_no_kw:
    ; Initialize saved state (needed for sort_done even on early exit)
    mov qword [rbp - LS_SAVED_ITEMS], 0
    mov qword [rbp - LS_SAVED_SIZE], 0
    mov qword [rbp - LS_SAVED_PAYLOADS], 0
    mov qword [rbp - LS_SAVED_TAGS], 0

    ; If n < 2, nothing to sort
    cmp r12, 2
    jl .sort_trivial_done

    ; Save list state and empty it during sort (mutation detection)
    mov rax, [rbx + PyListObject.ob_item]
    mov [rbp - LS_SAVED_PAYLOADS], rax
    mov rax, [rbx + PyListObject.ob_item_tags]
    mov [rbp - LS_SAVED_TAGS], rax
    mov [rbp - LS_SAVED_SIZE], r12

    ; Allocate fat buffer (n * 16) and copy payload+tag into it
    mov rdi, r12
    shl rdi, 4
    extern ap_malloc
    call ap_malloc
    mov [rbp - LS_SAVED_ITEMS], rax
    mov rdi, rax                          ; dest fat buffer
    mov rsi, [rbp - LS_SAVED_PAYLOADS]    ; src payloads
    mov rdx, [rbp - LS_SAVED_TAGS]        ; src tags
    xor rcx, rcx
.sort_copy_items:
    cmp rcx, r12
    jge .sort_copy_items_done
    mov r8, [rsi + rcx * 8]               ; payload
    movzx r9d, byte [rdx + rcx]           ; tag
    mov r10, rcx
    shl r10, 4
    mov [rdi + r10], r8
    mov [rdi + r10 + 8], r9
    inc rcx
    jmp .sort_copy_items
.sort_copy_items_done:

    mov qword [rbx + PyListObject.ob_item], 0
    mov qword [rbx + PyListObject.ob_item_tags], 0
    mov qword [rbx + PyListObject.ob_size], 0

    ; --- Pre-compute keys if key= provided ---
    cmp qword [rbp - LS_KEY], 0
    jz .sort_alloc_temp

    ; Allocate keys array: n * 16 bytes
    mov rdi, r12
    shl rdi, 4
    extern ap_malloc
    call ap_malloc
    mov [rbp - LS_KSRC], rax
    mov [rbp - LS_KORIG], rax      ; save original allocation for freeing
    mov r14, rax                   ; r14 = keys array

    ; Compute key(items[i]) for each i
    xor r15d, r15d                 ; i = 0
.sort_keys_loop:
    cmp r15, [rbp - LS_N]
    jge .sort_keys_done

    ; Get items[i] and push as single arg on stack (use saved items, list is empty during sort)
    mov rax, [rbp - LS_SAVED_ITEMS]
    mov rcx, r15
    shl rcx, 4
    mov rdi, [rax + rcx]          ; item payload
    mov rsi, [rax + rcx + 8]      ; item tag
    push rsi                       ; arg[0] tag
    push rdi                       ; arg[0] payload

    ; Get key function's tp_call
    mov rdi, [rbp - LS_KEY]
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_call]
    test rax, rax
    jz .sort_key_try_meta

    ; tp_call(rdi=callable, rsi=args, rdx=nargs)
    mov rsi, rsp                   ; args ptr → &[item]
    mov edx, 1                     ; nargs = 1
    call rax
    jmp .sort_key_store

.sort_key_try_meta:
    ; tp_call NULL — check if heaptype instance with __call__
    mov rdi, [rbp - LS_KEY]
    mov rax, [rdi + PyObject.ob_type]
    mov rdx, [rax + PyTypeObject.tp_flags]
    test rdx, TYPE_FLAG_HEAPTYPE
    jz .sort_key_meta_builtin

    ; Heaptype instance: use __call__(key, item) via dunder_call_2
    mov rsi, [rsp]                 ; other = item payload
    mov rcx, [rsp + 8]            ; other_tag = item tag
    extern dunder_call
    lea rdx, [rel dunder_call]
    extern dunder_call_2
    call dunder_call_2
    jmp .sort_key_store

.sort_key_meta_builtin:
    ; Built-in type: try metatype's tp_call (e.g., for type objects used as key)
    mov rdi, [rbp - LS_KEY]
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyObject.ob_type]  ; metatype
    mov rax, [rax + PyTypeObject.tp_call]
    test rax, rax
    jz .sort_key_error
    mov rsi, rsp
    mov edx, 1
    call rax

.sort_key_store:
    add rsp, 16                    ; pop item from stack
    ; rax = key result payload, edx = key result tag
    test edx, edx
    jz .sort_cleanup_keys          ; NULL return → error (item already popped)
    ; Store key in keys[i]
    mov rcx, r15
    shl rcx, 4
    mov [r14 + rcx], rax
    mov [r14 + rcx + 8], rdx
    inc r15
    jmp .sort_keys_loop

.sort_key_error:
    add rsp, 16                    ; pop item if still on stack
    ; DECREF any keys computed so far, free keys array
    jmp .sort_cleanup_keys

.sort_keys_done:
    ; Allocate keys temp array
    mov rdi, [rbp - LS_N]
    shl rdi, 4
    call ap_malloc
    mov [rbp - LS_KTEMP], rax
    mov [rbp - LS_KDST], rax

.sort_alloc_temp:
    ; Allocate temp array: n * 16 bytes
    mov rdi, [rbp - LS_N]
    shl rdi, 4
    call ap_malloc
    mov [rbp - LS_TEMP], rax
    mov [rbp - LS_DST], rax

    ; Source = saved list items array (list is empty during sort)
    mov rax, [rbp - LS_SAVED_ITEMS]
    mov [rbp - LS_SRC], rax

    ; =========================================================================
    ; Bottom-up merge sort: for width=1,2,4,...; merge adjacent pairs
    ; =========================================================================
    mov qword [rbp - LS_WIDTH], 1

.sort_width_loop:
    mov rax, [rbp - LS_WIDTH]
    cmp rax, [rbp - LS_N]
    jge .sort_width_done

    ; For i = 0; i < n; i += 2*width
    mov qword [rbp - LS_OUTI], 0

.sort_outer_loop:
    mov rax, [rbp - LS_OUTI]
    cmp rax, [rbp - LS_N]
    jge .sort_outer_done

    ; left = i
    mov [rbp - LS_MI], rax
    ; mid = min(i + width, n)
    add rax, [rbp - LS_WIDTH]
    cmp rax, [rbp - LS_N]
    jle .sort_mid_ok
    mov rax, [rbp - LS_N]
.sort_mid_ok:
    mov [rbp - LS_MMID], rax
    ; right_end = min(i + 2*width, n)
    mov rax, [rbp - LS_OUTI]
    mov rcx, [rbp - LS_WIDTH]
    lea rax, [rax + rcx*2]
    cmp rax, [rbp - LS_N]
    jle .sort_right_ok
    mov rax, [rbp - LS_N]
.sort_right_ok:
    mov [rbp - LS_MREND], rax
    ; k = i (dest index starts at i)
    mov rax, [rbp - LS_OUTI]
    mov [rbp - LS_MK], rax
    ; j = mid
    mov rax, [rbp - LS_MMID]
    mov [rbp - LS_MJ], rax

    ; =====================================================================
    ; Merge loop: merge src[left..mid) and src[mid..right_end) into dst
    ; =====================================================================
.merge_loop:
    ; Check if left run exhausted
    mov rax, [rbp - LS_MI]
    cmp rax, [rbp - LS_MMID]
    jge .merge_copy_right

    ; Check if right run exhausted
    mov rax, [rbp - LS_MJ]
    cmp rax, [rbp - LS_MREND]
    jge .merge_copy_left

    ; Load elements for comparison (use keys if available, else items)
    ; Python's sort uses right < left (PY_LT on right), not left > right.
    ; This ensures __lt__ works (more commonly defined than __gt__).
    mov rax, [rbp - LS_KSRC]
    test rax, rax
    jnz .merge_have_cmp_arr
    mov rax, [rbp - LS_SRC]
.merge_have_cmp_arr:
    ; For comparison: we do right < left (ascending) or right > left (descending)
    ; Load right element first (will be "self" in dunder call)
    mov rcx, [rbp - LS_MJ]
    shl rcx, 4
    mov rdi, [rax + rcx]          ; right payload (self for comparison)
    mov r8, [rax + rcx + 8]       ; right tag (full 64-bit)
    ; Load left element (will be "other" in dunder call)
    mov rcx, [rbp - LS_MI]
    shl rcx, 4
    mov rsi, [rax + rcx]          ; left payload (other for comparison)
    mov r9, [rax + rcx + 8]       ; left tag (full 64-bit)

    ; Type dispatch on right element for tp_richcompare
    ; Float coercion: if either operand is TAG_FLOAT, use float_compare
    cmp r8d, TAG_FLOAT
    je .merge_use_float
    cmp r9d, TAG_FLOAT
    je .merge_use_float

    cmp r8d, TAG_SMALLINT
    je .merge_si_type
    test r8d, TAG_RC_BIT
    jz .merge_take_left            ; TAG_NONE/TAG_BOOL: take left (stable)
    mov rax, [rdi + PyObject.ob_type]
    jmp .merge_have_type
.merge_si_type:
    lea rax, [rel int_type]
.merge_have_type:
    mov r10, rax                   ; save type ptr for dunder fallback
    mov rax, [rax + PyTypeObject.tp_richcompare]
    test rax, rax
    jz .merge_try_dunder

    ; tp_richcompare(rdi=right, rsi=left, edx=op, rcx=right_tag, r8=left_tag)
    ; Comparing: right < left (ascending) or right > left (descending)
    mov rcx, r8                    ; right_tag
    mov r8, r9                     ; left_tag
    cmp qword [rbp - LS_REV], 0
    je .merge_use_lt
    mov edx, PY_GT                 ; reversed: right > left
    jmp .merge_do_cmp
.merge_use_lt:
    mov edx, PY_LT                 ; normal: right < left
.merge_do_cmp:
    call rax
    jmp .merge_check_result

.merge_use_float:
    ; float_compare(right, left, op, right_tag, left_tag)
    extern float_compare
    mov rcx, r8                    ; right_tag (full 64-bit)
    mov r8, r9                     ; left_tag (full 64-bit)
    cmp qword [rbp - LS_REV], 0
    je .merge_float_lt
    mov edx, PY_GT                 ; reversed: right > left
    jmp .merge_float_cmp
.merge_float_lt:
    mov edx, PY_LT                 ; normal: right < left
.merge_float_cmp:
    call float_compare
    jmp .merge_check_result

.merge_try_dunder:
    ; No tp_richcompare — try dunder on heaptype (right side, the "self")
    mov rdx, [r10 + PyTypeObject.tp_flags]
    test rdx, TYPE_FLAG_HEAPTYPE
    jz .merge_take_left            ; not heaptype, give up

    ; Reload right/left from comparison array
    ; right = self, left = other (for right < left comparison)
    mov rax, [rbp - LS_KSRC]
    test rax, rax
    jnz .merge_dunder_have_arr
    mov rax, [rbp - LS_SRC]
.merge_dunder_have_arr:
    ; right element = self (index MJ)
    mov rcx, [rbp - LS_MJ]
    shl rcx, 4
    mov rdi, [rax + rcx]          ; right payload (self)
    mov r11d, [rax + rcx + 8]     ; right_tag (save temporarily)
    ; left element = other (index MI)
    mov rcx, [rbp - LS_MI]
    shl rcx, 4
    mov rsi, [rax + rcx]          ; left payload (other)
    mov ecx, [rax + rcx + 8]      ; left_tag (32-bit for dunder_call_2)

    ; dunder_call_2(rdi=self, rsi=other, rdx=name, ecx=other_tag)
    ; self=right, other=left: comparing right < left (ascending)
    cmp qword [rbp - LS_REV], 0
    je .merge_dunder_lt
    extern dunder_gt
    lea rdx, [rel dunder_gt]       ; reversed: right > left
    jmp .merge_dunder_call
.merge_dunder_lt:
    extern dunder_lt
    lea rdx, [rel dunder_lt]       ; normal: right < left
.merge_dunder_call:
    extern dunder_call_2
    call dunder_call_2
    ; fall through to check_result

.merge_check_result:
    ; (rax=payload, edx=tag) — check if comparison is true
    test edx, edx
    jz .merge_cmp_null             ; NULL → check for error or unorderable types
    cmp edx, TAG_BOOL
    je .merge_bool_result
    ; TAG_PTR: check for NotImplemented, then check bool_true
    extern notimpl_singleton
    lea rcx, [rel notimpl_singleton]
    cmp rax, rcx
    je .merge_cmp_type_error       ; NotImplemented → raise TypeError
    push rax                       ; save for DECREF
    lea rcx, [rel bool_true]
    cmp rax, rcx
    sete cl
    movzx ecx, cl                  ; ecx = 1 if true (take right)
    mov rdi, rax
    push rcx
    call obj_decref
    pop rcx
    add rsp, 8                     ; discard saved ptr
    test ecx, ecx
    jnz .merge_take_right
    jmp .merge_take_left

.merge_cmp_null:
    ; NULL return — check current_exception
    mov rax, [rel current_exception]
    test rax, rax
    jnz .sort_free_temp            ; real exception → cleanup and propagate
    ; No exception → unorderable types, raise TypeError
.merge_cmp_type_error:
    ; IMPORTANT: raise_exception does not return (non-local jump to eval_exception_unwind)
    ; Must free temp buffer and restore list state BEFORE raising.
    
    ; Free temp buffer
    mov rdi, [rbp - LS_TEMP]
    call ap_free
    
    ; If keys were used, DECREF keys and free arrays
    cmp qword [rbp - LS_KEY], 0
    jz .mcte_no_keys
    mov r14, [rbp - LS_KSRC]
    test r14, r14
    jz .mcte_free_ktemp
    xor r15d, r15d
.mcte_decref_keys:
    cmp r15, [rbp - LS_N]
    jge .mcte_free_keys
    mov rcx, r15
    shl rcx, 4
    mov rdi, [r14 + rcx]
    mov esi, [r14 + rcx + 8]
    DECREF_VAL rdi, rsi
    inc r15
    jmp .mcte_decref_keys
.mcte_free_keys:
    mov rdi, [rbp - LS_KORIG]
    call ap_free
    mov rdi, [rbp - LS_KTEMP]
    call ap_free
    jmp .mcte_restore_list
.mcte_free_ktemp:
    mov rdi, [rbp - LS_KTEMP]
    test rdi, rdi
    jz .mcte_restore_list
    call ap_free
.mcte_no_keys:
.mcte_restore_list:
    ; Restore list items (list is empty during sort)
    mov rbx, [rbp - LS_LIST]
    mov rax, [rbx + PyListObject.ob_item]
    test rax, rax
    jnz .mcte_already_restored     ; someone else restored
    mov rax, [rbp - LS_SAVED_PAYLOADS]
    mov [rbx + PyListObject.ob_item], rax
    mov rax, [rbp - LS_SAVED_TAGS]
    mov [rbx + PyListObject.ob_item_tags], rax
    mov rax, [rbp - LS_SAVED_SIZE]
    mov [rbx + PyListObject.ob_size], rax
.mcte_already_restored:
    ; Now raise TypeError
    extern exc_TypeError_type
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "'<' not supported between instances"
    extern raise_exception
    call raise_exception
    ; raise_exception does not return
.merge_bool_result:
    ; eax = 0 (false) or 1 (true)
    test eax, eax
    jnz .merge_take_right
    ; fall through: take left (equal → left wins for stability)

.merge_take_left:
    ; Copy src[left] to dst[k] (16 bytes)
    mov rax, [rbp - LS_SRC]
    mov rcx, [rbp - LS_MI]
    shl rcx, 4
    mov r8, [rax + rcx]
    mov r9, [rax + rcx + 8]
    mov rax, [rbp - LS_DST]
    mov rcx, [rbp - LS_MK]
    shl rcx, 4
    mov [rax + rcx], r8
    mov [rax + rcx + 8], r9
    ; If keys, copy ksrc[left] to kdst[k]
    mov rax, [rbp - LS_KSRC]
    test rax, rax
    jz .merge_left_nokeys
    mov rcx, [rbp - LS_MI]
    shl rcx, 4
    mov r8, [rax + rcx]
    mov r9, [rax + rcx + 8]
    mov rax, [rbp - LS_KDST]
    mov rcx, [rbp - LS_MK]
    shl rcx, 4
    mov [rax + rcx], r8
    mov [rax + rcx + 8], r9
.merge_left_nokeys:
    inc qword [rbp - LS_MI]
    inc qword [rbp - LS_MK]
    jmp .merge_loop

.merge_take_right:
    ; Copy src[j] to dst[k] (16 bytes)
    mov rax, [rbp - LS_SRC]
    mov rcx, [rbp - LS_MJ]
    shl rcx, 4
    mov r8, [rax + rcx]
    mov r9, [rax + rcx + 8]
    mov rax, [rbp - LS_DST]
    mov rcx, [rbp - LS_MK]
    shl rcx, 4
    mov [rax + rcx], r8
    mov [rax + rcx + 8], r9
    ; If keys, copy ksrc[j] to kdst[k]
    mov rax, [rbp - LS_KSRC]
    test rax, rax
    jz .merge_right_nokeys
    mov rcx, [rbp - LS_MJ]
    shl rcx, 4
    mov r8, [rax + rcx]
    mov r9, [rax + rcx + 8]
    mov rax, [rbp - LS_KDST]
    mov rcx, [rbp - LS_MK]
    shl rcx, 4
    mov [rax + rcx], r8
    mov [rax + rcx + 8], r9
.merge_right_nokeys:
    inc qword [rbp - LS_MJ]
    inc qword [rbp - LS_MK]
    jmp .merge_loop

.merge_copy_right:
    ; Left exhausted — copy remaining right elements to dst
    mov rax, [rbp - LS_MJ]
    cmp rax, [rbp - LS_MREND]
    jge .merge_done
    mov rax, [rbp - LS_SRC]
    mov rcx, [rbp - LS_MJ]
    shl rcx, 4
    mov r8, [rax + rcx]
    mov r9, [rax + rcx + 8]
    mov rax, [rbp - LS_DST]
    mov rcx, [rbp - LS_MK]
    shl rcx, 4
    mov [rax + rcx], r8
    mov [rax + rcx + 8], r9
    ; Keys
    mov rax, [rbp - LS_KSRC]
    test rax, rax
    jz .merge_cr_nokeys
    mov rcx, [rbp - LS_MJ]
    shl rcx, 4
    mov r8, [rax + rcx]
    mov r9, [rax + rcx + 8]
    mov rax, [rbp - LS_KDST]
    mov rcx, [rbp - LS_MK]
    shl rcx, 4
    mov [rax + rcx], r8
    mov [rax + rcx + 8], r9
.merge_cr_nokeys:
    inc qword [rbp - LS_MJ]
    inc qword [rbp - LS_MK]
    jmp .merge_copy_right

.merge_copy_left:
    ; Right exhausted — copy remaining left elements to dst
    mov rax, [rbp - LS_MI]
    cmp rax, [rbp - LS_MMID]
    jge .merge_done
    mov rax, [rbp - LS_SRC]
    mov rcx, [rbp - LS_MI]
    shl rcx, 4
    mov r8, [rax + rcx]
    mov r9, [rax + rcx + 8]
    mov rax, [rbp - LS_DST]
    mov rcx, [rbp - LS_MK]
    shl rcx, 4
    mov [rax + rcx], r8
    mov [rax + rcx + 8], r9
    ; Keys
    mov rax, [rbp - LS_KSRC]
    test rax, rax
    jz .merge_cl_nokeys
    mov rcx, [rbp - LS_MI]
    shl rcx, 4
    mov r8, [rax + rcx]
    mov r9, [rax + rcx + 8]
    mov rax, [rbp - LS_KDST]
    mov rcx, [rbp - LS_MK]
    shl rcx, 4
    mov [rax + rcx], r8
    mov [rax + rcx + 8], r9
.merge_cl_nokeys:
    inc qword [rbp - LS_MI]
    inc qword [rbp - LS_MK]
    jmp .merge_copy_left

.merge_done:
    ; Advance to next pair of runs
    mov rax, [rbp - LS_OUTI]
    mov rcx, [rbp - LS_WIDTH]
    lea rax, [rax + rcx*2]
    mov [rbp - LS_OUTI], rax
    jmp .sort_outer_loop

.sort_outer_done:
    ; Swap src/dst pointers (result now in "new src" for next pass)
    mov rax, [rbp - LS_SRC]
    mov rcx, [rbp - LS_DST]
    mov [rbp - LS_SRC], rcx
    mov [rbp - LS_DST], rax
    ; Swap keys src/dst if keys exist
    mov rax, [rbp - LS_KSRC]
    test rax, rax
    jz .sort_no_key_swap
    mov rcx, [rbp - LS_KDST]
    mov [rbp - LS_KSRC], rcx
    mov [rbp - LS_KDST], rax
.sort_no_key_swap:
    ; width *= 2
    shl qword [rbp - LS_WIDTH], 1
    jmp .sort_width_loop

.sort_width_done:
    ; After loop, result is in LS_SRC. If not list's items, copy back.
    mov rax, [rbp - LS_SAVED_ITEMS]
    cmp rax, [rbp - LS_SRC]
    je .sort_free_temp             ; result already in items

    ; memcpy items ← src, n*16 bytes
    mov rdi, rax                   ; dest = saved items
    mov rsi, [rbp - LS_SRC]       ; src = temp (where result is)
    mov rdx, [rbp - LS_N]
    shl rdx, 4                     ; byte count
    extern ap_memcpy
    call ap_memcpy

.sort_free_temp:
    ; Free temp array
    mov rdi, [rbp - LS_TEMP]
    extern ap_free
    call ap_free

    ; If keys were used, DECREF all keys and free arrays
    cmp qword [rbp - LS_KEY], 0
    jz .sort_done

    ; DECREF each key in the final keys array (in LS_KSRC after swaps)
    mov r14, [rbp - LS_KSRC]
    test r14, r14
    jz .sort_free_ktemp
    xor r15d, r15d
.sort_decref_keys:
    cmp r15, [rbp - LS_N]
    jge .sort_free_keys
    mov rcx, r15
    shl rcx, 4
    mov rdi, [r14 + rcx]          ; key payload
    mov esi, [r14 + rcx + 8]      ; key tag
    DECREF_VAL rdi, rsi
    inc r15
    jmp .sort_decref_keys

.sort_free_keys:
    ; Free both keys arrays (use LS_KORIG not LS_KSRC - they may swap)
    mov rdi, [rbp - LS_KORIG]
    call ap_free
    mov rdi, [rbp - LS_KTEMP]
    call ap_free
    jmp .sort_done

.sort_free_ktemp:
    mov rdi, [rbp - LS_KTEMP]
    test rdi, rdi
    jz .sort_done
    call ap_free
    jmp .sort_done

.sort_cleanup_keys:
    ; Error during key computation — DECREF computed keys and free
    mov r14, [rbp - LS_KSRC]
    test r14, r14
    jz .sort_done
    xor r13d, r13d
.sort_cleanup_keys_loop:
    cmp r13, r15                   ; r15 = keys computed so far
    jge .sort_cleanup_keys_free
    mov rcx, r13
    shl rcx, 4
    mov rdi, [r14 + rcx]
    mov esi, [r14 + rcx + 8]
    DECREF_VAL rdi, rsi
    inc r13
    jmp .sort_cleanup_keys_loop
.sort_cleanup_keys_free:
    mov rdi, r14
    call ap_free
    ; Error path: propagate exception (return TAG_NULL)
    extern current_exception
    mov rax, [rel current_exception]
    test rax, rax
    jnz .sort_error_return

.sort_trivial_done:
    ; n < 2, no sort needed, return None
    lea rax, [rel none_singleton]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.sort_done:
    ; Restore list state: put sorted items back
    mov rbx, [rbp - LS_LIST]
    ; Check if list was mutated during sort (ob_item or ob_size changed)
    mov rax, [rbx + PyListObject.ob_item]
    test rax, rax
    jnz .sort_mutated              ; ob_item != NULL → someone put items back
    mov rax, [rbx + PyListObject.ob_item_tags]
    test rax, rax
    jnz .sort_mutated              ; ob_item_tags != NULL → someone put items back
    mov rax, [rbx + PyListObject.ob_size]
    test rax, rax
    jnz .sort_mutated              ; ob_size != 0 → someone changed it

    ; No mutation: copy sorted fat buffer back to payload/tag arrays
    mov rdi, [rbp - LS_SAVED_ITEMS]       ; fat buffer
    mov rsi, [rbp - LS_SAVED_PAYLOADS]    ; payloads
    mov rdx, [rbp - LS_SAVED_TAGS]        ; tags
    mov rcx, [rbp - LS_SAVED_SIZE]
    xor r8d, r8d
.sort_copy_back:
    cmp r8, rcx
    jge .sort_copy_back_done
    mov r9, r8
    shl r9, 4
    mov r10, [rdi + r9]           ; payload
    mov r11, [rdi + r9 + 8]       ; tag (low byte)
    mov [rsi + r8 * 8], r10
    mov byte [rdx + r8], r11b
    inc r8
    jmp .sort_copy_back
.sort_copy_back_done:
    ; Free fat buffer
    mov rdi, [rbp - LS_SAVED_ITEMS]
    test rdi, rdi
    jz .sort_restore_ptrs
    call ap_free
    mov qword [rbp - LS_SAVED_ITEMS], 0
.sort_restore_ptrs:
    ; Restore list pointers and size
    mov rax, [rbp - LS_SAVED_PAYLOADS]
    mov [rbx + PyListObject.ob_item], rax
    mov rax, [rbp - LS_SAVED_TAGS]
    mov [rbx + PyListObject.ob_item_tags], rax
    mov rax, [rbp - LS_SAVED_SIZE]
    mov [rbx + PyListObject.ob_size], rax

    ; Check if an exception was raised during sort
    mov rax, [rel current_exception]
    test rax, rax
    jnz .sort_error_return
    lea rax, [rel none_singleton]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.sort_mutated:
    ; List was mutated during sort — this is an error
    ; IMPORTANT: raise_exception does not return (non-local jump)
    ; Must cleanup BEFORE raising.
    
    ; First free temp buffer (allocated during sort)
    mov rdi, [rbp - LS_TEMP]
    call ap_free
    
    ; If keys were used, DECREF keys and free arrays
    cmp qword [rbp - LS_KEY], 0
    jz .sm_no_keys
    mov r14, [rbp - LS_KSRC]
    test r14, r14
    jz .sm_free_ktemp
    xor r15d, r15d
.sm_decref_keys:
    cmp r15, [rbp - LS_N]
    jge .sm_free_keys
    mov rcx, r15
    shl rcx, 4
    mov rdi, [r14 + rcx]
    mov esi, [r14 + rcx + 8]
    DECREF_VAL rdi, rsi
    inc r15
    jmp .sm_decref_keys
.sm_free_keys:
    mov rdi, [rbp - LS_KORIG]
    call ap_free
    mov rdi, [rbp - LS_KTEMP]
    call ap_free
    jmp .sm_handle_mutation
.sm_free_ktemp:
    mov rdi, [rbp - LS_KTEMP]
    test rdi, rdi
    jz .sm_handle_mutation
    call ap_free
.sm_no_keys:
.sm_handle_mutation:
    ; Save mutated items for cleanup
    mov rcx, [rbx + PyListObject.ob_item]       ; mutated payloads
    mov r9, [rbx + PyListObject.ob_item_tags]   ; mutated tags
    mov r8, [rbx + PyListObject.ob_size]

    ; Restore our sorted items from fat buffer
    mov rdi, [rbp - LS_SAVED_ITEMS]       ; fat buffer
    mov rsi, [rbp - LS_SAVED_PAYLOADS]
    mov rdx, [rbp - LS_SAVED_TAGS]
    mov r10, [rbp - LS_SAVED_SIZE]
    xor r11d, r11d
.sort_mut_copy_back:
    cmp r11, r10
    jge .sort_mut_copy_back_done
    mov rax, r11
    shl rax, 4
    mov r12, [rdi + rax]          ; payload
    mov r13, [rdi + rax + 8]      ; tag
    mov [rsi + r11 * 8], r12
    mov byte [rdx + r11], r13b
    inc r11
    jmp .sort_mut_copy_back
.sort_mut_copy_back_done:
    ; Free fat buffer
    mov rdi, [rbp - LS_SAVED_ITEMS]
    test rdi, rdi
    jz .sort_mut_restore_ptrs
    call ap_free
.sort_mut_restore_ptrs:
    mov rax, [rbp - LS_SAVED_PAYLOADS]
    mov [rbx + PyListObject.ob_item], rax
    mov rax, [rbp - LS_SAVED_TAGS]
    mov [rbx + PyListObject.ob_item_tags], rax
    mov rax, [rbp - LS_SAVED_SIZE]
    mov [rbx + PyListObject.ob_size], rax

    ; DECREF all mutated items and free the arrays
    push rcx
    push r9
    push r8
    test rcx, rcx
    jz .sort_mut_no_decref
    xor r11d, r11d
.sort_mut_decref_loop:
    cmp r11, r8
    jge .sort_mut_decref_done
    mov rdi, [rcx + r11 * 8]          ; payload
    movzx esi, byte [r9 + r11]        ; tag
    push rcx
    push r9
    push r8
    push r11
    DECREF_VAL rdi, rsi
    pop r11
    pop r8
    pop r9
    pop rcx
    inc r11
    jmp .sort_mut_decref_loop
.sort_mut_decref_done:
    mov rdi, rcx
    call ap_free
    mov rdi, r9
    call ap_free
.sort_mut_no_decref:
    pop r8
    pop r9
    pop rcx
    ; Raise ValueError
    lea rdi, [rel exc_ValueError_type]
    CSTRING rsi, "list modified during sort"
    call raise_exception
    ; raise_exception does not return

.sort_error_return:
    ; Restore list items if still saved (error during sort before merge)
    mov rbx, [rbp - LS_LIST]
    mov rax, [rbx + PyListObject.ob_item]
    test rax, rax
    jnz .sort_error_already_restored
    ; List is still empty — restore saved pointers
    mov rax, [rbp - LS_SAVED_PAYLOADS]
    mov [rbx + PyListObject.ob_item], rax
    mov rax, [rbp - LS_SAVED_TAGS]
    mov [rbx + PyListObject.ob_item_tags], rax
    mov rax, [rbp - LS_SAVED_SIZE]
    mov [rbx + PyListObject.ob_size], rax
.sort_error_already_restored:
    ; Free fat buffer if allocated
    mov rdi, [rbp - LS_SAVED_ITEMS]
    test rdi, rdi
    jz .sort_error_done
    call ap_free
.sort_error_done:
    RET_NULL
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC list_method_sort

;; ============================================================================
;; list_method_index(args, nargs) -> SmallInt index
;; args[0]=self, args[1]=value, optional args[2]=start, args[3]=stop
;; Linear scan with identity check then __eq__ protocol
;; ============================================================================
LI_LIST   equ 8
LI_VPAY   equ 16   ; value payload
LI_VTAG   equ 24   ; value tag
LI_IDX    equ 32
LI_SIZE   equ 40
LI_ARGS   equ 48   ; save args pointer
LI_NARGS  equ 56   ; save nargs
LI_FRAME  equ 56
DEF_FUNC list_method_index, LI_FRAME
    push rbx
    push r12

    mov [rbp - LI_ARGS], rdi  ; save args
    mov [rbp - LI_NARGS], rsi ; save nargs
    mov rax, [rdi]           ; self
    mov [rbp - LI_LIST], rax
    mov rax, [rdi + 16]      ; value payload
    mov [rbp - LI_VPAY], rax
    mov rax, [rdi + 24]      ; value tag
    mov [rbp - LI_VTAG], rax
    mov rcx, [rbp - LI_LIST]
    mov rcx, [rcx + PyListObject.ob_size]

    ; Default stop = list size
    mov [rbp - LI_SIZE], rcx

    ; Default start = 0
    mov qword [rbp - LI_IDX], 0

    ; Check for optional start arg (nargs >= 3)
    cmp qword [rbp - LI_NARGS], 3
    jl .li_have_bounds
    ; Get start from args[2]
    mov rax, [rbp - LI_ARGS]
    mov rdi, [rax + 32]      ; args[2] payload
    mov edx, [rax + 40]      ; args[2] tag
    call int_to_i64
    ; Handle negative start
    test rax, rax
    jns .li_start_pos
    add rax, [rbp - LI_SIZE]  ; start += len
    test rax, rax
    jns .li_start_pos
    xor eax, eax              ; clamp to 0
.li_start_pos:
    mov [rbp - LI_IDX], rax

    ; Check for optional stop arg (nargs >= 4)
    cmp qword [rbp - LI_NARGS], 4
    jl .li_have_bounds
    ; Get stop from args[3]
    mov rax, [rbp - LI_ARGS]
    mov rdi, [rax + 48]      ; args[3] payload
    mov edx, [rax + 56]      ; args[3] tag
    call int_to_i64
    ; Handle negative stop
    test rax, rax
    jns .li_stop_pos
    add rax, [rbp - LI_SIZE]  ; stop += len
    test rax, rax
    jns .li_stop_pos
    xor eax, eax              ; clamp to 0
.li_stop_pos:
    ; Clamp stop to list size
    mov rcx, [rbp - LI_LIST]
    mov rcx, [rcx + PyListObject.ob_size]
    cmp rax, rcx
    jle .li_stop_ok
    mov rax, rcx
.li_stop_ok:
    mov [rbp - LI_SIZE], rax

.li_have_bounds:

.index_loop:
    mov rax, [rbp - LI_IDX]
    cmp rax, [rbp - LI_SIZE]
    jge .index_not_found

    ; Load element payload+tag
    mov rbx, [rbp - LI_LIST]
    mov rbx, [rbx + PyListObject.ob_item]
    mov rdx, [rbp - LI_LIST]
    mov rdx, [rdx + PyListObject.ob_item_tags]
    mov rdi, [rbx + rax * 8]      ; elem payload
    movzx r8d, byte [rdx + rax]   ; elem tag

    ; Fast identity: both payload AND tag match → found
    cmp rdi, [rbp - LI_VPAY]
    jne .index_try_eq
    cmp r8, [rbp - LI_VTAG]
    je .index_found

.index_try_eq:
    ; Resolve element type
    mov r12, r8
    cmp r8d, TAG_SMALLINT
    je .index_int_type
    cmp r8d, TAG_FLOAT
    je .index_float_type
    test r8, r8
    js .index_str_type
    cmp r8d, TAG_BOOL
    je .index_next
    test r8d, TAG_RC_BIT
    jz .index_next
    mov rax, [rdi + PyObject.ob_type]
    jmp .index_have_type
.index_int_type:
    lea rax, [rel int_type]
    jmp .index_have_type
.index_float_type:
    extern float_type
    lea rax, [rel float_type]
    jmp .index_have_type
.index_str_type:
    extern str_type
    lea rax, [rel str_type]
.index_have_type:
    mov rbx, rax               ; save type ptr
    mov rax, [rax + PyTypeObject.tp_richcompare]
    test rax, rax
    jnz .index_do_richcmp

    ; No tp_richcompare — try dunder on heaptype
    mov rdx, [rbx + PyTypeObject.tp_flags]
    test rdx, TYPE_FLAG_HEAPTYPE
    jz .index_next
    ; rdi = elem (already set)
    mov rsi, [rbp - LI_VPAY]
    CSTRING rdx, "__eq__"
    mov ecx, [rbp - LI_VTAG]
    call dunder_call_2
    test edx, edx
    jz .index_next
    jmp .index_check_result

.index_do_richcmp:
    ; tp_richcompare(elem, value, PY_EQ, elem_tag, value_tag)
    mov rsi, [rbp - LI_VPAY]
    mov edx, PY_EQ
    mov rcx, r12
    mov r8, [rbp - LI_VTAG]
    call rax
    ; Check for NotImplemented (NULL return = tag 0)
    test edx, edx
    jz .index_next

.index_check_result:
    ; Check truthiness
    push rax
    push rdx
    mov rdi, rax
    mov rsi, rdx
    call obj_is_true
    mov ebx, eax
    pop rdx
    pop rdi
    push rbx
    mov rsi, rdx
    DECREF_VAL rdi, rsi
    pop rbx
    test ebx, ebx
    jnz .index_found

.index_next:
    inc qword [rbp - LI_IDX]
    jmp .index_loop

.index_found:
    mov rdi, [rbp - LI_IDX]
    call int_from_i64
    pop r12
    pop rbx
    leave
    ret

.index_not_found:
    lea rdi, [rel exc_ValueError_type]
    CSTRING rsi, "x not in list"
    call raise_exception
END_FUNC list_method_index

;; ============================================================================
;; list_method_count(args, nargs) -> SmallInt
;; args[0]=self, args[1]=value
;; ============================================================================
LC_IDX    equ 8
LC_FRAME  equ 8

DEF_FUNC list_method_count, LC_FRAME
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rbx, [rdi]          ; self
    mov r12, [rdi + 16]     ; value payload
    mov r15d, [rdi + 24]    ; value tag
    mov r13, [rbx + PyListObject.ob_size]
    xor r14d, r14d          ; count = 0

    mov qword [rbp - LC_IDX], 0
.count_loop:
    mov rcx, [rbp - LC_IDX]
    cmp rcx, r13
    jge .count_done
    mov rax, [rbx + PyListObject.ob_item]
    mov rdx, [rbx + PyListObject.ob_item_tags]
    mov rdi, [rax + rcx * 8]    ; item payload
    movzx r8d, byte [rdx + rcx] ; item tag

    ; Fast path: identity (both payload AND tag match)
    cmp rdi, r12
    jne .count_eq_dispatch
    cmp r8, r15
    je .count_hit

.count_eq_dispatch:
    ; __eq__ dispatch via tp_richcompare
    cmp r8d, TAG_SMALLINT
    je .count_eq_int
    cmp r8d, TAG_FLOAT
    je .count_eq_float
    cmp r8d, TAG_BOOL
    je .count_next            ; TAG_BOOL: identity only
    test r8d, TAG_RC_BIT
    jz .count_next            ; TAG_NONE etc: skip
    mov rax, [rdi + PyObject.ob_type]
    jmp .count_eq_call
.count_eq_int:
    lea rax, [rel int_type]
    jmp .count_eq_call
.count_eq_float:
    lea rax, [rel float_type]
.count_eq_call:
    mov rcx, rax               ; save type ptr
    mov rax, [rax + PyTypeObject.tp_richcompare]
    test rax, rax
    jnz .count_do_richcmp

    ; No tp_richcompare — try dunder on heaptype
    mov rdx, [rcx + PyTypeObject.tp_flags]
    test rdx, TYPE_FLAG_HEAPTYPE
    jz .count_next
    extern dunder_call_2
    ; rdi = item (already set)
    mov rsi, r12               ; other = value
    CSTRING rdx, "__eq__"
    mov ecx, r15d              ; other_tag = value tag
    call dunder_call_2
    test edx, edx
    jz .count_next
    jmp .count_check_result

.count_do_richcmp:
    ; tp_richcompare(item, value, PY_EQ, item_tag, value_tag)
    mov rsi, r12
    mov edx, PY_EQ
    mov rcx, r8               ; item tag
    mov r8, r15               ; value tag
    call rax
    ; Check for NotImplemented (NULL return = tag 0)
    test edx, edx
    jz .count_next

.count_check_result:
    ; Check result truthiness (handles both TAG_BOOL and TAG_PTR bool)
    push rax
    push rdx
    mov rdi, rax
    mov rsi, rdx
    call obj_is_true
    mov ecx, eax               ; save truthiness
    pop rdx
    pop rdi
    push rcx
    mov rsi, rdx
    DECREF_VAL rdi, rsi
    pop rcx
    test ecx, ecx
    jnz .count_hit
    jmp .count_next

.count_hit:
    inc r14
.count_next:
    inc qword [rbp - LC_IDX]
    jmp .count_loop

.count_done:
    mov rdi, r14
    call int_from_i64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC list_method_count

;; ============================================================================
;; list_method_copy(args, nargs) -> new list (shallow copy)
;; args[0]=self
;; ============================================================================
DEF_FUNC list_method_copy
    push rbx
    push r12
    push r13

    mov rbx, [rdi]          ; self
    mov r12, [rbx + PyListObject.ob_size]

    ; Create new list with same capacity
    mov rdi, r12
    test rdi, rdi
    jnz .copy_alloc
    mov rdi, 4
.copy_alloc:
    call list_new
    mov r13, rax            ; new list

    ; Append each item (list_append does INCREF)
    xor ecx, ecx
.copy_loop:
    cmp rcx, r12
    jge .copy_done
    push rcx
    mov rax, [rbx + PyListObject.ob_item]
    mov rdx, [rbx + PyListObject.ob_item_tags]
    mov rsi, [rax + rcx * 8]    ; payload
    movzx edx, byte [rdx + rcx] ; tag
    mov rdi, r13
    call list_append
    pop rcx
    inc rcx
    jmp .copy_loop

.copy_done:
    mov rax, r13
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC list_method_copy

;; ============================================================================
;; list_method_clear(args, nargs) -> None
;; args[0]=self
;; ============================================================================
DEF_FUNC list_method_clear
    push rbx
    push r12
    push r13

    mov rbx, [rdi]          ; self
    ; Check if list is being sorted (ob_item == NULL)
    cmp qword [rbx + PyListObject.ob_item], 0
    je list_sorting_error
    mov r12, [rbx + PyListObject.ob_size]

    ; DECREF all items (fat 16-byte slots)
    xor r13d, r13d
.clear_loop:
    cmp r13, r12
    jge .clear_done
    mov rax, [rbx + PyListObject.ob_item]
    mov rcx, [rbx + PyListObject.ob_item_tags]
    mov rdi, [rax + r13 * 8]    ; payload
    movzx esi, byte [rcx + r13] ; tag
    push r13
    DECREF_VAL rdi, rsi
    pop r13
    inc r13
    jmp .clear_loop

.clear_done:
    mov qword [rbx + PyListObject.ob_size], 0

    lea rax, [rel none_singleton]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC list_method_clear

;; ============================================================================
;; list_method_extend(args, nargs) -> None
;; args[0]=self, args[1]=iterable (list, tuple, or generic iterable)
;; ============================================================================
LE_SELF   equ 8
LE_ITER   equ 16
LE_FRAME  equ 16
DEF_FUNC list_method_extend, LE_FRAME
    push rbx
    push r12
    push r13

    mov rbx, [rdi]           ; self
    ; Check if list is being sorted (ob_item == NULL)
    cmp qword [rbx + PyListObject.ob_item], 0
    je list_sorting_error
    mov r12, [rdi + 16]      ; iterable payload
    mov r13, [rdi + 24]      ; iterable tag
    mov [rbp - LE_SELF], rbx

    ; Check iterable type for fast paths
    test r13d, TAG_RC_BIT
    jz .extend_generic         ; non-pointer → must use generic iter

    mov rax, [r12 + PyObject.ob_type]
    lea rcx, [rel list_type]
    cmp rax, rcx
    je .extend_list
    lea rcx, [rel tuple_type]
    cmp rax, rcx
    je .extend_tuple

    ; Generic iterable path
    jmp .extend_generic

.extend_list:
    mov r13, [r12 + PyListObject.ob_size]
    xor ecx, ecx
.extend_list_loop:
    cmp rcx, r13
    jge .extend_done
    push rcx
    mov rax, [r12 + PyListObject.ob_item]
    mov rdx, [r12 + PyListObject.ob_item_tags]
    mov rsi, [rax + rcx * 8]       ; payload
    movzx edx, byte [rdx + rcx]    ; tag
    mov rdi, [rbp - LE_SELF]
    call list_append
    pop rcx
    inc rcx
    jmp .extend_list_loop

.extend_tuple:
    mov r13, [r12 + PyTupleObject.ob_size]
    xor ecx, ecx
.extend_tuple_loop:
    cmp rcx, r13
    jge .extend_done
    push rcx
    mov rax, [r12 + PyTupleObject.ob_item]
    mov rdx, [r12 + PyTupleObject.ob_item_tags]
    mov rsi, [rax + rcx * 8]      ; payload
    movzx edx, byte [rdx + rcx]   ; tag
    mov rdi, [rbp - LE_SELF]
    call list_append
    pop rcx
    inc rcx
    jmp .extend_tuple_loop

.extend_generic:
    ; Get tp_iter from iterable type
    test r13d, TAG_RC_BIT
    jz .extend_type_error       ; non-pointer has no tp_iter
    mov rax, [r12 + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iter]
    test rax, rax
    jz .extend_type_error
    mov rdi, r12
    call rax                    ; tp_iter(iterable) → iterator
    test rax, rax
    jz .extend_type_error
    mov [rbp - LE_ITER], rax

.extend_iter_loop:
    mov rdi, [rbp - LE_ITER]
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_iternext]
    test rax, rax
    jz .extend_iter_done
    mov rdi, [rbp - LE_ITER]
    call rax                    ; tp_iternext(iter) → (payload, tag)
    test edx, edx
    jz .extend_iter_done        ; StopIteration

    ; Append item to list
    push rax
    push rdx
    mov rdi, [rbp - LE_SELF]
    mov rsi, rax
    ; edx = tag (already set)
    call list_append
    ; DECREF item (list_append INCREFs internally)
    pop rsi                     ; tag
    pop rdi                     ; payload
    DECREF_VAL rdi, rsi
    jmp .extend_iter_loop

.extend_iter_done:
    ; DECREF iterator
    mov rdi, [rbp - LE_ITER]
    call obj_decref

.extend_done:
    lea rax, [rel none_singleton]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret

.extend_type_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "list.extend() argument must be iterable"
    call raise_exception
END_FUNC list_method_extend


;; ############################################################################
;;                         DICT METHODS
;; ############################################################################

;; ============================================================================
;; dict_method_get(args, nargs) -> value or None
;; args[0]=self, args[1]=key, optionally args[2]=default
;; ============================================================================
DEF_FUNC dict_method_get
    push rbx
    push r12

    mov rax, rdi            ; args
    mov rbx, [rax]          ; self (dict)
    mov r12, rsi            ; nargs
    push rax

    ; dict_get(self, key)
    mov rdi, rbx
    mov rsi, [rax + 16]     ; key payload
    mov rdx, [rax + 24]     ; key tag
    call dict_get

    test edx, edx
    jnz .dg_found

    ; Not found - return default or None
    pop rcx                 ; args
    cmp r12, 3
    jl .dg_ret_none
    ; Return args[2] (default)
    mov rax, [rcx + 32]     ; default payload
    mov rdx, [rcx + 40]     ; default tag
    INCREF_VAL rax, rdx
    pop r12
    pop rbx
    leave
    ret

.dg_ret_none:
    lea rax, [rel none_singleton]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

.dg_found:
    add rsp, 8              ; discard saved args
    ; INCREF the value (dict_get returns borrowed ref, rdx=tag)
    INCREF_VAL rax, rdx
    ; rdx already has correct tag from dict_get
    pop r12
    pop rbx
    leave
    ret
END_FUNC dict_method_get

;; ============================================================================
;; dict_method_keys(args, nargs) -> dict_keys view
;; args[0]=self
;; ============================================================================
extern dict_view_new
DEF_FUNC dict_method_keys
    mov rdi, [rdi]          ; self (dict)
    xor esi, esi            ; kind=0 (keys)
    extern dict_keys_view_type
    lea rdx, [rel dict_keys_view_type]
    call dict_view_new
    mov edx, TAG_PTR
    leave
    ret
END_FUNC dict_method_keys

;; ============================================================================
;; dict_method_values(args, nargs) -> dict_values view
;; args[0]=self
;; ============================================================================
DEF_FUNC dict_method_values
    mov rdi, [rdi]          ; self (dict)
    mov esi, 1              ; kind=1 (values)
    extern dict_values_view_type
    lea rdx, [rel dict_values_view_type]
    call dict_view_new
    mov edx, TAG_PTR
    leave
    ret
END_FUNC dict_method_values

;; ============================================================================
;; dict_method_items(args, nargs) -> dict_items view
;; args[0]=self
;; ============================================================================
DEF_FUNC dict_method_items
    mov rdi, [rdi]          ; self (dict)
    mov esi, 2              ; kind=2 (items)
    extern dict_items_view_type
    lea rdx, [rel dict_items_view_type]
    call dict_view_new
    mov edx, TAG_PTR
    leave
    ret
END_FUNC dict_method_items

;; ============================================================================
;; dict_method_pop(args, nargs) -> value
;; args[0]=self, args[1]=key, optionally args[2]=default
;; ============================================================================
DEF_FUNC dict_method_pop
dict_method_pop_v2 equ dict_method_pop
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r14, rdi            ; r14 = args
    mov rbx, [r14]          ; self
    mov r12, rsi            ; nargs
    mov r13, [r14 + 16]     ; key payload (16-byte stride)
    mov r15d, [r14 + 24]    ; key tag

    ; Try dict_get
    mov rdi, rbx
    mov rsi, r13
    mov edx, r15d           ; key tag
    call dict_get
    test edx, edx
    jz .dpop2_not_found

    ; dict_get returns fat (rax=payload, rdx=tag)
    INCREF_VAL rax, rdx
    push rdx                ; save tag across dict_del
    push rax                ; save payload

    mov rdi, rbx
    mov rsi, r13
    mov rdx, r15            ; key tag
    call dict_del

    pop rax                 ; restore payload
    pop rdx                 ; restore tag
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.dpop2_not_found:
    cmp r12, 3
    jl .dpop2_error
    mov rax, [r14 + 32]     ; default = args[2] payload (16-byte stride)
    mov rdx, [r14 + 40]     ; default tag
    INCREF_VAL rax, rdx
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.dpop2_error:
    lea rdi, [rel exc_KeyError_type]
    CSTRING rsi, "key not found"
    call raise_exception
END_FUNC dict_method_pop

;; ============================================================================
;; dict_method_clear(args, nargs) -> None
;; args[0]=self
;; ============================================================================
DEF_FUNC dict_method_clear
    push rbx
    push r12
    push r13
    push r14

    mov rbx, [rdi]          ; self (dict)

    ; DECREF all keys and values
    mov r12, [rbx + PyDictObject.capacity]
    xor r13d, r13d

.dc_loop:
    cmp r13, r12
    jge .dc_clear_entries

    mov rax, [rbx + PyDictObject.entries]
    imul rcx, r13, DICT_ENTRY_SIZE
    lea r14, [rax + rcx]    ; r14 = entry ptr

    mov rdi, [r14 + DictEntry.key]
    test rdi, rdi
    jz .dc_next

    ; DECREF key (tag-aware)
    movzx esi, byte [r14 + DictEntry.key_tag]
    DECREF_VAL rdi, rsi

    ; DECREF value (tag-aware)
    mov rdi, [r14 + DictEntry.value]
    movzx esi, byte [r14 + DictEntry.value_tag]
    DECREF_VAL rdi, rsi

.dc_next:
    inc r13
    jmp .dc_loop

.dc_clear_entries:
    ; Zero out all entries
    mov rdi, [rbx + PyDictObject.entries]
    xor esi, esi
    imul rdx, r12, DICT_ENTRY_SIZE
    call ap_memset

    ; Reset size to 0
    mov qword [rbx + PyDictObject.ob_size], 0

    lea rax, [rel none_singleton]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC dict_method_clear

;; ============================================================================
;; dict_method_update(args, nargs) -> None
;; args[0]=self, args[1]=other_dict
;; Merge other_dict into self
;; ============================================================================
DEF_FUNC dict_method_update
    push rbx
    push r12
    push r13
    push r14

    mov rbx, [rdi]          ; self

    ; If nargs == 1 (just self, no args), return None immediately
    cmp rsi, 1
    jle .du_done

    mov r12, [rdi + 16]     ; other dict

    mov r13, [r12 + PyDictObject.capacity]
    xor r14d, r14d

.du_loop:
    cmp r14, r13
    jge .du_done

    mov rax, [r12 + PyDictObject.entries]
    imul rcx, r14, DICT_ENTRY_SIZE
    add rax, rcx

    mov rdi, [rax + DictEntry.key]
    test rdi, rdi
    jz .du_next
    movzx ecx, byte [rax + DictEntry.value_tag]
    test ecx, ecx
    jz .du_next                 ; TAG_NULL = empty slot

    ; dict_set(self, key, value, value_tag, key_tag)
    push r14
    movzx r8d, byte [rax + DictEntry.key_tag]    ; key tag from entry
    movzx ecx, byte [rax + DictEntry.value_tag]  ; value tag from entry
    mov rdx, [rax + DictEntry.value]      ; value payload
    mov rsi, rdi            ; key
    mov rdi, rbx            ; self
    call dict_set
    pop r14

.du_next:
    inc r14
    jmp .du_loop

.du_done:
    lea rax, [rel none_singleton]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC dict_method_update

;; ============================================================================
;; dict_method_setdefault(args, nargs) -> value
;; args[0]=self, args[1]=key, args[2]=default (optional, default=None)
;; ============================================================================
DEF_FUNC dict_method_setdefault
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rbx, [rdi]          ; self (dict)
    mov r12, [rdi + 16]     ; key payload
    mov r14d, [rdi + 24]    ; key tag
    mov r13, rsi            ; nargs

    ; Save args ptr for default value access
    push rdi

    ; dict_get(self, key)
    mov rdi, rbx
    mov rsi, r12
    mov edx, r14d           ; key tag
    call dict_get

    test edx, edx
    jnz .sd_found

    ; Not found - determine default value
    pop rdi                 ; restore args ptr
    cmp r13, 3
    jl .sd_use_none
    mov r13, [rdi + 32]     ; default = args[2] payload
    mov r15d, [rdi + 40]    ; default = args[2] tag
    jmp .sd_set_default

.sd_use_none:
    lea r13, [rel none_singleton]
    mov r15d, TAG_PTR

.sd_set_default:
    ; dict_set(self, key, default_val)
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov ecx, r15d           ; default val tag
    mov r8d, r14d           ; key tag
    call dict_set

    ; INCREF and return default_val
    INCREF_VAL r13, r15
    mov rax, r13
    mov edx, r15d           ; return tag
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.sd_found:
    add rsp, 8              ; discard saved args ptr
    ; INCREF the found value (dict_get returns borrowed ref, rdx=tag)
    INCREF_VAL rax, rdx
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC dict_method_setdefault

;; ============================================================================
;; dict_method_copy(args, nargs) -> new dict (shallow copy)
;; args[0]=self
;; ============================================================================
DEF_FUNC dict_method_copy
    push rbx
    push r12
    push r13
    push r14

    mov rbx, [rdi]          ; self (dict)

    ; Create new dict
    call dict_new
    mov r12, rax            ; r12 = new dict

    ; Iterate over self's entries
    mov r13, [rbx + PyDictObject.capacity]
    xor r14d, r14d          ; index

.dcopy_loop:
    cmp r14, r13
    jge .dcopy_done

    mov rax, [rbx + PyDictObject.entries]
    imul rcx, r14, DICT_ENTRY_SIZE
    add rax, rcx

    mov rdi, [rax + DictEntry.key]
    test rdi, rdi
    jz .dcopy_next
    movzx ecx, byte [rax + DictEntry.value_tag]
    test ecx, ecx
    jz .dcopy_next              ; TAG_NULL = empty slot

    ; dict_set(new_dict, key, value, value_tag, key_tag)
    push r14
    movzx r8d, byte [rax + DictEntry.key_tag]    ; key tag from entry
    movzx ecx, byte [rax + DictEntry.value_tag]  ; value tag from entry
    mov rdx, [rax + DictEntry.value]      ; value payload
    mov rsi, rdi            ; key
    mov rdi, r12            ; new dict
    call dict_set
    pop r14

.dcopy_next:
    inc r14
    jmp .dcopy_loop

.dcopy_done:
    mov rax, r12
    mov edx, TAG_PTR         ; dict is heap ptr
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC dict_method_copy

;; ============================================================================
;; dict_classmethod_fromkeys(args, nargs) -> new dict
;; args[0]=cls (type), args[1]=iterable, optional args[2]=value (default None)
;; Creates dict from iterable keys with given value.
;; ============================================================================
DFK_ITER  equ 8
DFK_DICT  equ 16
DFK_VAL   equ 24
DFK_VTAG  equ 32
DFK_FRAME equ 40

DEF_FUNC dict_classmethod_fromkeys, DFK_FRAME
    push rbx
    push r12
    push r13

    ; Default value = None (payload=0, tag=TAG_NONE)
    mov qword [rbp - DFK_VAL], 0
    mov qword [rbp - DFK_VTAG], TAG_NONE

    ; If nargs >= 3, use args[2] as value
    cmp rsi, 3
    jl .dfk_get_iter
    mov rax, [rdi + 32]            ; value payload
    mov rcx, [rdi + 40]            ; value tag
    mov [rbp - DFK_VAL], rax
    mov [rbp - DFK_VTAG], rcx

.dfk_get_iter:
    ; Get iterator from args[1] (iterable)
    ; args array: [0]=cls, [8]=cls_tag, [16]=iterable, [24]=iterable_tag, ...
    mov rax, rdi                   ; save args ptr
    mov rdi, [rax + 16]            ; iterable payload
    mov esi, [rax + 24]            ; iterable tag
    extern get_iterator
    call get_iterator
    mov [rbp - DFK_ITER], rax

    ; Create new dict
    call dict_new
    mov [rbp - DFK_DICT], rax

.dfk_loop:
    ; Get next key from iterator
    mov rdi, [rbp - DFK_ITER]
    extern call_iternext
    call call_iternext
    test edx, edx
    jz .dfk_done                   ; iterator exhausted

    ; rax=key payload, rdx=key tag
    ; Save key before loading value (which overwrites rdx)
    mov rsi, rax                   ; key payload
    mov r8, rdx                    ; key tag

    ; dict_set(dict, key, value, value_tag, key_tag)
    mov rdi, [rbp - DFK_DICT]
    mov rdx, [rbp - DFK_VAL]       ; value payload (overwrites old rdx)
    mov rcx, [rbp - DFK_VTAG]      ; value tag
    call dict_set

    jmp .dfk_loop

.dfk_done:
    ; DECREF iterator
    mov rdi, [rbp - DFK_ITER]
    call obj_decref

    mov rax, [rbp - DFK_DICT]
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC dict_classmethod_fromkeys

;; ============================================================================
;; dict_method_popitem(args, nargs) -> (key, value) tuple
;; args[0]=self. Removes and returns last inserted item.
;; ============================================================================
DEF_FUNC dict_method_popitem
    push rbx
    push r12
    push r13
    push r14

    mov rbx, [rdi]          ; self (dict)

    ; Check if dict is empty
    cmp qword [rbx + PyDictObject.ob_size], 0
    je .dpopitem_empty

    ; Find last non-NULL entry by scanning backward
    mov r12, [rbx + PyDictObject.capacity]
    dec r12                  ; start from capacity-1

.dpopitem_scan:
    cmp r12, 0
    jl .dpopitem_empty       ; shouldn't happen, but safety
    mov rax, [rbx + PyDictObject.entries]
    imul rcx, r12, DICT_ENTRY_SIZE
    add rax, rcx

    mov r13, [rax + DictEntry.key]
    test r13, r13
    jz .dpopitem_prev
    movzx ecx, byte [rax + DictEntry.value_tag]
    test rcx, rcx
    jz .dpopitem_prev           ; TAG_NULL = empty slot
    mov r14, [rax + DictEntry.value]
    jmp .dpopitem_found

.dpopitem_prev:
    dec r12
    jmp .dpopitem_scan

.dpopitem_found:
    ; r13 = key, r14 = value, rcx = value_tag
    ; Also save key_tag from the entry
    mov rax, [rbx + PyDictObject.entries]
    imul rdx, r12, DICT_ENTRY_SIZE
    add rax, rdx
    movzx r8d, byte [rax + DictEntry.key_tag]
    push r8                  ; save key_tag
    push rcx                 ; save value_tag across tuple_new
    ; Create 2-tuple
    mov rdi, 2
    call tuple_new
    pop rcx                  ; restore value_tag
    pop r8                   ; restore key_tag
    mov r12, rax             ; r12 = tuple

    ; Set tuple[0] = key with correct tag, tuple[1] = value
    mov r9, [r12 + PyTupleObject.ob_item]
    mov r10, [r12 + PyTupleObject.ob_item_tags]
    mov [r9], r13
    mov byte [r10], r8b     ; key tag from entry
    INCREF_VAL r13, r8
    mov [r9 + 8], r14
    mov byte [r10 + 1], cl  ; value tag from entry
    INCREF_VAL r14, rcx

    ; Delete key from dict
    mov rdi, rbx
    mov rsi, r13
    movzx edx, byte [r10]   ; key tag
    call dict_del

    mov rax, r12
    mov edx, TAG_PTR         ; tuple is heap ptr
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.dpopitem_empty:
    lea rdi, [rel exc_KeyError_type]
    CSTRING rsi, "dictionary is empty"
    call raise_exception
END_FUNC dict_method_popitem

;; ============================================================================
;; list_method_remove(args, nargs) -> None
;; args[0]=self, args[1]=value
;; Removes first occurrence of value. Raises ValueError if not found.
;; ============================================================================
DEF_FUNC list_method_remove
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rbx, [rdi]          ; self (list)
    ; Check if list is being sorted (ob_item == NULL)
    cmp qword [rbx + PyListObject.ob_item], 0
    je list_sorting_error
    mov r12, [rdi + 16]     ; value payload
    mov r15d, [rdi + 24]    ; value tag
    mov r13, [rbx + PyListObject.ob_size]

    xor r14d, r14d          ; index = 0

.lremove_loop:
    cmp r14, r13
    jge .lremove_not_found

    mov rax, [rbx + PyListObject.ob_item]
    mov rdx, [rbx + PyListObject.ob_item_tags]
    mov rdi, [rax + r14 * 8]    ; item payload
    movzx r8d, byte [rdx + r14] ; item tag

    ; Fast path: identity (both payload AND tag match)
    cmp rdi, r12
    jne .lremove_eq_dispatch
    cmp r8, r15
    je .lremove_found

.lremove_eq_dispatch:
    ; __eq__ dispatch: get item type's tp_richcompare
    cmp r8d, TAG_SMALLINT
    je .lremove_eq_int
    cmp r8d, TAG_FLOAT
    je .lremove_eq_float
    cmp r8d, TAG_BOOL
    je .lremove_next          ; TAG_BOOL: identity only
    test r8d, TAG_RC_BIT
    jz .lremove_next          ; TAG_NONE etc: skip
    mov rax, [rdi + PyObject.ob_type]
    jmp .lremove_eq_call
.lremove_eq_int:
    lea rax, [rel int_type]
    jmp .lremove_eq_call
.lremove_eq_float:
    lea rax, [rel float_type]
.lremove_eq_call:
    mov rcx, rax              ; save type ptr
    mov rax, [rax + PyTypeObject.tp_richcompare]
    test rax, rax
    jnz .lremove_do_richcmp

    ; No tp_richcompare — try dunder on heaptype
    mov rdx, [rcx + PyTypeObject.tp_flags]
    test rdx, TYPE_FLAG_HEAPTYPE
    jz .lremove_next
    ; rdi = item (already set)
    mov rsi, r12             ; other = value
    CSTRING rdx, "__eq__"
    mov ecx, r15d            ; other_tag = value tag
    call dunder_call_2
    test edx, edx
    jz .lremove_next
    jmp .lremove_check_result

.lremove_do_richcmp:
    ; tp_richcompare(item, value, PY_EQ, item_tag, right_tag)
    ; rdi = item payload (already set)
    mov rsi, r12             ; value payload
    mov edx, PY_EQ
    mov rcx, r8              ; item tag
    mov r8, r15              ; value tag
    call rax
    ; Check for NotImplemented (NULL return = tag 0)
    test edx, edx
    jz .lremove_next

.lremove_check_result:
    ; Check result truthiness (handles TAG_BOOL and TAG_PTR bool)
    push rax
    push rdx
    mov rdi, rax
    mov rsi, rdx
    call obj_is_true
    mov ecx, eax
    pop rdx
    pop rdi
    push rcx
    mov rsi, rdx
    DECREF_VAL rdi, rsi
    pop rcx
    test ecx, ecx
    jnz .lremove_found

.lremove_next:
    inc r14
    jmp .lremove_loop

.lremove_found:
    ; r14 = index of found item
    ; Get the item for DECREF (read payload + tag)
    mov rax, [rbx + PyListObject.ob_item]
    mov rcx, [rbx + PyListObject.ob_item_tags]
    mov r12, [rax + r14 * 8]        ; item payload
    movzx r13d, byte [rcx + r14]    ; item tag

    ; Shift payloads left: memmove(&payloads[idx], &payloads[idx+1], (size-1-idx)*8)
    mov rax, [rbx + PyListObject.ob_item]
    lea rdi, [rax + r14 * 8]
    lea rsi, [rdi + 8]
    mov rdx, [rbx + PyListObject.ob_size]
    sub rdx, r14
    dec rdx                 ; count = size - idx - 1
    shl rdx, 3              ; bytes = count * 8
    jz .lremove_shift_tags
    call ap_memmove

.lremove_shift_tags:
    ; Shift tags left: memmove(&tags[idx], &tags[idx+1], count)
    mov rax, [rbx + PyListObject.ob_item_tags]
    lea rdi, [rax + r14]
    lea rsi, [rdi + 1]
    mov rdx, [rbx + PyListObject.ob_size]
    sub rdx, r14
    dec rdx
    jz .lremove_shrink      ; nothing to shift if removing last
    call ap_memmove

.lremove_shrink:
    dec qword [rbx + PyListObject.ob_size]

    ; DECREF the removed item (fat value)
    mov rdi, r12
    mov rsi, r13
    DECREF_VAL rdi, rsi

    ; Return None
    lea rax, [rel none_singleton]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.lremove_not_found:
    lea rdi, [rel exc_ValueError_type]
    CSTRING rsi, "list.remove(x): x not in list"
    call raise_exception
END_FUNC list_method_remove

;; ============================================================================
;; list_method_reversed(args, nargs) -> reversed iterator
;; args[0]=self
;; ============================================================================
extern reversed_iter_type
DEF_FUNC list_method_reversed
    push rbx

    mov rbx, [rdi]            ; self (list)

    ; Allocate ReversedIterObject (32 bytes: refcnt, type, it_seq, it_index)
    mov edi, 32
    call ap_malloc

    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel reversed_iter_type]
    mov [rax + PyObject.ob_type], rcx
    mov [rax + 16], rbx       ; it_seq = self
    INCREF rbx
    mov rcx, [rbx + PyListObject.ob_size]
    dec rcx                   ; it_index = ob_size - 1
    mov [rax + 24], rcx

    mov edx, TAG_PTR
    pop rbx
    leave
    ret
END_FUNC list_method_reversed

;; ============================================================================
;; tuple_method_index(args, nargs) -> SmallInt index
;; args[0]=self (tuple), args[1]=value, optional args[2]=start, args[3]=stop
;; ============================================================================
DEF_FUNC tuple_method_index, 16
    push rbx
    push r12
    push r13
    push r14

    mov [rbp - 8], rdi      ; save args
    mov [rbp - 16], rsi     ; save nargs
    mov rbx, [rdi]          ; self (tuple)
    mov r12, [rdi + 16]     ; value to find (payload)
    mov r14d, [rdi + 24]    ; value tag
    mov r13, [rbx + PyTupleObject.ob_size]  ; default stop = size

    xor ecx, ecx            ; default start = 0

    ; Check for optional start arg (nargs >= 3)
    cmp qword [rbp - 16], 3
    jl .ti_have_bounds
    mov rax, [rbp - 8]
    push rcx
    mov rdi, [rax + 32]      ; args[2] payload
    mov edx, [rax + 40]      ; args[2] tag
    call int_to_i64
    pop rcx
    mov rcx, rax
    ; Handle negative start
    test rcx, rcx
    jns .ti_start_pos
    add rcx, r13
    test rcx, rcx
    jns .ti_start_pos
    xor ecx, ecx
.ti_start_pos:

    ; Check for optional stop arg (nargs >= 4)
    cmp qword [rbp - 16], 4
    jl .ti_have_bounds
    mov rax, [rbp - 8]
    push rcx
    mov rdi, [rax + 48]      ; args[3] payload
    mov edx, [rax + 56]      ; args[3] tag
    call int_to_i64
    pop rcx
    ; Handle negative stop
    test rax, rax
    jns .ti_stop_pos
    add rax, r13
    test rax, rax
    jns .ti_stop_pos
    xor eax, eax
.ti_stop_pos:
    cmp rax, r13
    jle .ti_stop_ok
    mov rax, r13
.ti_stop_ok:
    mov r13, rax            ; r13 = stop

.ti_have_bounds:
.tindex_loop:
    cmp rcx, r13
    jge .tindex_not_found

    mov rsi, [rbx + PyTupleObject.ob_item]       ; payloads
    mov rdx, [rbx + PyTupleObject.ob_item_tags]  ; tags
    mov rax, [rsi + rcx * 8]
    movzx r8d, byte [rdx + rcx]

    ; Check exact match (payload + tag)
    cmp rax, r12
    jne .tindex_check_smallint
    cmp r8d, r14d
    je .tindex_found

.tindex_check_smallint:
    ; Check SmallInt equality
    cmp r8d, TAG_SMALLINT
    jne .tindex_check_str
    cmp r14d, TAG_SMALLINT
    jne .tindex_next
    cmp rax, r12
    je .tindex_found
    jmp .tindex_next

.tindex_check_str:
    ; Try string comparison: if both are str_type, compare data
    mov rsi, rax             ; tuple item
    cmp r14d, TAG_PTR
    jne .tindex_next
    cmp r8d, TAG_PTR
    jne .tindex_next
    mov rax, [r12 + PyObject.ob_type]
    lea r8, [rel str_type]
    cmp rax, r8
    jne .tindex_next
    mov rax, [rsi + PyObject.ob_type]
    cmp rax, r8
    jne .tindex_next
    ; Both strings - compare
    push rcx
    push rsi
    lea rdi, [r12 + PyStrObject.data]
    lea rsi, [rsi + PyStrObject.data]
    call ap_strcmp
    pop rsi
    pop rcx
    test eax, eax
    jz .tindex_found

.tindex_next:
    inc rcx
    jmp .tindex_loop

.tindex_found:
    mov rdi, rcx
    call int_from_i64
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.tindex_not_found:
    lea rdi, [rel exc_ValueError_type]
    CSTRING rsi, "tuple.index(x): x not in tuple"
    call raise_exception
END_FUNC tuple_method_index

;; ============================================================================
;; tuple_method_count(args, nargs) -> SmallInt
;; args[0]=self (tuple), args[1]=value
;; ============================================================================
DEF_FUNC tuple_method_count
    push rbx
    push r12
    push r13
    push r14

    mov rbx, [rdi]          ; self (tuple)
    mov r12, [rdi + 16]     ; value
    mov r13, [rbx + PyTupleObject.ob_size]
    xor r14d, r14d          ; count = 0

    xor ecx, ecx
.tcount_loop:
    cmp rcx, r13
    jge .tcount_done

    mov rax, [rbx + PyTupleObject.ob_item]
    mov rax, [rax + rcx * 8]

    ; Check pointer equality
    cmp rax, r12
    jne .tcount_next
    inc r14

.tcount_next:
    inc rcx
    jmp .tcount_loop

.tcount_done:
    mov rdi, r14
    call int_from_i64
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC tuple_method_count


;; ############################################################################
;;                         SET METHODS
;; ############################################################################

;; ============================================================================
;; set_method_add(args, nargs) -> None
;; args[0]=self, args[1]=elem
;; ============================================================================
DEF_FUNC set_method_add
    cmp rsi, 2
    jne .sma_error

    mov rax, rdi            ; args ptr
    mov rdi, [rax]          ; self (set)
    mov rsi, [rax + 16]     ; elem payload
    mov rdx, [rax + 24]     ; elem tag
    call set_add

    lea rax, [rel none_singleton]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    ret

.sma_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "add() takes exactly one argument"
    call raise_exception
END_FUNC set_method_add

;; ============================================================================
;; set_method_remove(args, nargs) -> None (raises KeyError if missing)
;; args[0]=self, args[1]=elem
;; ============================================================================
DEF_FUNC set_method_remove
    cmp rsi, 2
    jne .smr_error

    mov rax, rdi
    mov rdi, [rax]          ; self
    mov rsi, [rax + 16]     ; elem payload
    mov rdx, [rax + 24]     ; elem tag
    call set_remove
    test eax, eax
    jnz .smr_keyerr

    lea rax, [rel none_singleton]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    ret

.smr_keyerr:
    lea rdi, [rel exc_KeyError_type]
    CSTRING rsi, "element not in set"
    call raise_exception

.smr_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "remove() takes exactly one argument"
    call raise_exception
END_FUNC set_method_remove

;; ============================================================================
;; set_method_discard(args, nargs) -> None (no error if missing)
;; args[0]=self, args[1]=elem
;; ============================================================================
DEF_FUNC set_method_discard
    cmp rsi, 2
    jne .smd_error

    mov rax, rdi
    mov rdi, [rax]          ; self
    mov rsi, [rax + 16]     ; elem payload
    mov rdx, [rax + 24]     ; elem tag
    call set_remove
    ; Ignore return value (don't care if not found)

    lea rax, [rel none_singleton]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    ret

.smd_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "discard() takes exactly one argument"
    call raise_exception
END_FUNC set_method_discard

;; ============================================================================
;; set_method_pop(args, nargs) -> removed element
;; args[0]=self
;; Scans for first occupied entry, removes and returns it.
;; ============================================================================
SMP_FRAME equ 16    ; save self + entry ptr
DEF_FUNC set_method_pop, SMP_FRAME
    push rbx
    push r12
    push r13

    cmp rsi, 1
    jne .smpop_error

    mov rbx, [rdi]          ; self (set)

    ; Check empty
    cmp qword [rbx + PyDictObject.ob_size], 0
    je .smpop_empty

    ; Scan for first non-empty entry
    mov r12, [rbx + PyDictObject.entries]
    mov r13, [rbx + PyDictObject.capacity]
    xor ecx, ecx            ; index

.smpop_scan:
    cmp rcx, r13
    jge .smpop_empty         ; shouldn't happen

    imul rax, rcx, SET_ENTRY_SIZE
    add rax, r12             ; entry ptr

    cmp qword [rax + SET_ENTRY_KEY_TAG], 0
    jne .smpop_found
    inc ecx
    jmp .smpop_scan

.smpop_found:
    ; rax = entry ptr with valid key
    ; Get key (return value) — DON'T incref, we're removing it
    mov rcx, [rax + SET_ENTRY_KEY]        ; key payload
    mov r12d, [rax + SET_ENTRY_KEY_TAG]   ; key tag

    ; Clear the entry (mark as empty)
    mov qword [rax + SET_ENTRY_KEY], 0
    mov qword [rax + SET_ENTRY_KEY_TAG], 0
    dec qword [rbx + PyDictObject.ob_size]

    ; Return the key (ownership transfers, no INCREF/DECREF needed)
    mov rax, rcx
    mov edx, r12d
    pop r13
    pop r12
    pop rbx
    leave
    ret

.smpop_empty:
    lea rdi, [rel exc_KeyError_type]
    CSTRING rsi, "pop from an empty set"
    call raise_exception

.smpop_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "pop() takes no arguments"
    call raise_exception
END_FUNC set_method_pop

;; ============================================================================
;; set_method_clear(args, nargs) -> None
;; args[0]=self
;; ============================================================================
DEF_FUNC set_method_clear
    push rbx
    push r12
    push r13

    cmp rsi, 1
    jne .smc_error

    mov rbx, [rdi]          ; self (set)
    mov r12, [rbx + PyDictObject.entries]
    mov r13, [rbx + PyDictObject.capacity]
    xor ecx, ecx

.smc_loop:
    cmp rcx, r13
    jge .smc_done

    imul rax, rcx, SET_ENTRY_SIZE
    add rax, r12
    push rcx                ; save index

    cmp qword [rax + SET_ENTRY_KEY_TAG], 0
    je .smc_next

    ; DECREF key
    mov rdi, [rax + SET_ENTRY_KEY]
    mov rsi, [rax + SET_ENTRY_KEY_TAG]
    mov qword [rax + SET_ENTRY_KEY], 0
    mov qword [rax + SET_ENTRY_KEY_TAG], 0
    DECREF_VAL rdi, rsi

.smc_next:
    pop rcx
    inc ecx
    jmp .smc_loop

.smc_done:
    mov qword [rbx + PyDictObject.ob_size], 0

    lea rax, [rel none_singleton]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret

.smc_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "clear() takes no arguments"
    call raise_exception
END_FUNC set_method_clear

;; ============================================================================
;; set_method_copy(args, nargs) -> new set (shallow copy)
;; args[0]=self
;; ============================================================================
DEF_FUNC set_method_copy
    push rbx
    push r12
    push r13
    push r14

    cmp rsi, 1
    jne .smcp_error

    mov r14, [rdi]          ; self (source set)

    ; Create new empty set
    call set_new
    mov rbx, rax            ; rbx = new set

    ; Iterate source entries
    mov r12, [r14 + PyDictObject.entries]
    mov r13, [r14 + PyDictObject.capacity]
    xor ecx, ecx

.smcp_loop:
    cmp rcx, r13
    jge .smcp_done

    imul rax, rcx, SET_ENTRY_SIZE
    add rax, r12
    push rcx

    cmp qword [rax + SET_ENTRY_KEY_TAG], 0
    je .smcp_next

    ; Add key to new set
    mov rdi, rbx            ; new set
    mov rsi, [rax + SET_ENTRY_KEY]
    mov rdx, [rax + SET_ENTRY_KEY_TAG]
    call set_add

.smcp_next:
    pop rcx
    inc ecx
    jmp .smcp_loop

.smcp_done:
    mov rax, rbx
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.smcp_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "copy() takes no arguments"
    call raise_exception
END_FUNC set_method_copy

;; ============================================================================
;; set_method_union(args, nargs) -> new set = self | other
;; args[0]=self, args[1]=other (iterable)
;; ============================================================================
DEF_FUNC set_method_union
    push rbx
    push r12
    push r13
    push r14
    push r15

    cmp rsi, 2
    jne .smu_error

    mov r14, [rdi]          ; self
    mov r15, [rdi + 16]     ; other set

    ; Copy self → new set
    mov r12, [r14 + PyDictObject.entries]
    mov r13, [r14 + PyDictObject.capacity]
    call set_new
    mov rbx, rax            ; new set
    xor ecx, ecx

.smu_copy_self:
    cmp rcx, r13
    jge .smu_add_other

    imul rax, rcx, SET_ENTRY_SIZE
    add rax, r12
    push rcx

    cmp qword [rax + SET_ENTRY_KEY_TAG], 0
    je .smu_cs_next

    mov rdi, rbx
    mov rsi, [rax + SET_ENTRY_KEY]
    mov rdx, [rax + SET_ENTRY_KEY_TAG]
    call set_add

.smu_cs_next:
    pop rcx
    inc ecx
    jmp .smu_copy_self

.smu_add_other:
    ; Now add all elements from other
    mov r12, [r15 + PyDictObject.entries]
    mov r13, [r15 + PyDictObject.capacity]
    xor ecx, ecx

.smu_add_loop:
    cmp rcx, r13
    jge .smu_done

    imul rax, rcx, SET_ENTRY_SIZE
    add rax, r12
    push rcx

    cmp qword [rax + SET_ENTRY_KEY_TAG], 0
    je .smu_al_next

    mov rdi, rbx
    mov rsi, [rax + SET_ENTRY_KEY]
    mov rdx, [rax + SET_ENTRY_KEY_TAG]
    call set_add

.smu_al_next:
    pop rcx
    inc ecx
    jmp .smu_add_loop

.smu_done:
    mov rax, rbx
    mov edx, TAG_PTR
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.smu_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "union() takes exactly one argument"
    call raise_exception
END_FUNC set_method_union

;; ============================================================================
;; set_method_update(args, nargs) -> None
;; args[0]=self, args[1]=other (set). Adds all elements of other to self.
;; ============================================================================
DEF_FUNC set_method_update
    push rbx
    push r12
    push r13

    mov rbx, [rdi]          ; self
    ; If no other arg, no-op
    cmp rsi, 2
    jl .supd_done

    mov r12, [rdi + 16]     ; other set
    mov r13, [r12 + PyDictObject.capacity]
    xor ecx, ecx

.supd_loop:
    cmp rcx, r13
    jge .supd_done

    imul rax, rcx, SET_ENTRY_SIZE
    add rax, [r12 + PyDictObject.entries]
    push rcx

    cmp qword [rax + SET_ENTRY_KEY_TAG], 0
    je .supd_next

    mov rdi, rbx
    mov rsi, [rax + SET_ENTRY_KEY]
    mov rdx, [rax + SET_ENTRY_KEY_TAG]
    call set_add

.supd_next:
    pop rcx
    inc ecx
    jmp .supd_loop

.supd_done:
    extern none_singleton
    lea rax, [rel none_singleton]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC set_method_update

;; ============================================================================
;; set_method_intersection(args, nargs) -> new set = self & other
;; args[0]=self, args[1]=other
;; ============================================================================
DEF_FUNC set_method_intersection
    push rbx
    push r12
    push r13
    push r14
    push r15

    cmp rsi, 2
    jne .smi_error

    mov r14, [rdi]          ; self
    mov r15, [rdi + 16]     ; other

    call set_new
    mov rbx, rax            ; new set

    ; Iterate self, add if in other
    mov r12, [r14 + PyDictObject.entries]
    mov r13, [r14 + PyDictObject.capacity]
    xor ecx, ecx

.smi_loop:
    cmp rcx, r13
    jge .smi_done

    imul rax, rcx, SET_ENTRY_SIZE
    add rax, r12
    push rcx

    cmp qword [rax + SET_ENTRY_KEY_TAG], 0
    je .smi_next

    ; Check if key is in other
    push rax                ; save entry ptr
    mov rdi, r15            ; other set
    mov rsi, [rax + SET_ENTRY_KEY]
    mov rdx, [rax + SET_ENTRY_KEY_TAG]
    call set_contains
    pop rcx                 ; restore entry ptr (was rax)
    test eax, eax
    jz .smi_next

    ; In both — add to result
    mov rdi, rbx
    mov rsi, [rcx + SET_ENTRY_KEY]
    mov rdx, [rcx + SET_ENTRY_KEY_TAG]
    call set_add

.smi_next:
    pop rcx
    inc ecx
    jmp .smi_loop

.smi_done:
    mov rax, rbx
    mov edx, TAG_PTR
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.smi_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "intersection() takes exactly one argument"
    call raise_exception
END_FUNC set_method_intersection

;; ============================================================================
;; set_method_difference(args, nargs) -> new set = self - other
;; args[0]=self, args[1]=other
;; ============================================================================
DEF_FUNC set_method_difference
    push rbx
    push r12
    push r13
    push r14
    push r15

    cmp rsi, 2
    jne .smdf_error

    mov r14, [rdi]          ; self
    mov r15, [rdi + 16]     ; other

    call set_new
    mov rbx, rax            ; new set

    ; Iterate self, add if NOT in other
    mov r12, [r14 + PyDictObject.entries]
    mov r13, [r14 + PyDictObject.capacity]
    xor ecx, ecx

.smdf_loop:
    cmp rcx, r13
    jge .smdf_done

    imul rax, rcx, SET_ENTRY_SIZE
    add rax, r12
    push rcx

    cmp qword [rax + SET_ENTRY_KEY_TAG], 0
    je .smdf_next

    ; Check if key is in other
    push rax
    mov rdi, r15
    mov rsi, [rax + SET_ENTRY_KEY]
    mov rdx, [rax + SET_ENTRY_KEY_TAG]
    call set_contains
    pop rcx                 ; entry ptr
    test eax, eax
    jnz .smdf_next          ; in other — skip

    ; NOT in other — add to result
    mov rdi, rbx
    mov rsi, [rcx + SET_ENTRY_KEY]
    mov rdx, [rcx + SET_ENTRY_KEY_TAG]
    call set_add

.smdf_next:
    pop rcx
    inc ecx
    jmp .smdf_loop

.smdf_done:
    mov rax, rbx
    mov edx, TAG_PTR
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.smdf_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "difference() takes exactly one argument"
    call raise_exception
END_FUNC set_method_difference

;; ============================================================================
;; set_method_symmetric_difference(args, nargs) -> new set = self ^ other
;; args[0]=self, args[1]=other
;; ============================================================================
DEF_FUNC set_method_symmetric_difference
    push rbx
    push r12
    push r13
    push r14
    push r15

    cmp rsi, 2
    jne .smsd_error

    mov r14, [rdi]          ; self
    mov r15, [rdi + 16]     ; other

    call set_new
    mov rbx, rax            ; new set

    ; Add elements in self but NOT in other
    mov r12, [r14 + PyDictObject.entries]
    mov r13, [r14 + PyDictObject.capacity]
    xor ecx, ecx

.smsd_self_loop:
    cmp rcx, r13
    jge .smsd_other

    imul rax, rcx, SET_ENTRY_SIZE
    add rax, r12
    push rcx

    cmp qword [rax + SET_ENTRY_KEY_TAG], 0
    je .smsd_s_next

    push rax
    mov rdi, r15
    mov rsi, [rax + SET_ENTRY_KEY]
    mov rdx, [rax + SET_ENTRY_KEY_TAG]
    call set_contains
    pop rcx
    test eax, eax
    jnz .smsd_s_next        ; in other, skip

    mov rdi, rbx
    mov rsi, [rcx + SET_ENTRY_KEY]
    mov rdx, [rcx + SET_ENTRY_KEY_TAG]
    call set_add

.smsd_s_next:
    pop rcx
    inc ecx
    jmp .smsd_self_loop

.smsd_other:
    ; Add elements in other but NOT in self
    mov r12, [r15 + PyDictObject.entries]
    mov r13, [r15 + PyDictObject.capacity]
    xor ecx, ecx

.smsd_other_loop:
    cmp rcx, r13
    jge .smsd_done

    imul rax, rcx, SET_ENTRY_SIZE
    add rax, r12
    push rcx

    cmp qword [rax + SET_ENTRY_KEY_TAG], 0
    je .smsd_o_next

    push rax
    mov rdi, r14
    mov rsi, [rax + SET_ENTRY_KEY]
    mov rdx, [rax + SET_ENTRY_KEY_TAG]
    call set_contains
    pop rcx
    test eax, eax
    jnz .smsd_o_next        ; in self, skip

    mov rdi, rbx
    mov rsi, [rcx + SET_ENTRY_KEY]
    mov rdx, [rcx + SET_ENTRY_KEY_TAG]
    call set_add

.smsd_o_next:
    pop rcx
    inc ecx
    jmp .smsd_other_loop

.smsd_done:
    mov rax, rbx
    mov edx, TAG_PTR
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.smsd_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "symmetric_difference() takes exactly one argument"
    call raise_exception
END_FUNC set_method_symmetric_difference

;; ============================================================================
;; set_method_issubset(args, nargs) -> bool
;; args[0]=self, args[1]=other
;; True if every element of self is in other.
;; ============================================================================
DEF_FUNC set_method_issubset
    push rbx
    push r12
    push r13
    push r14
    push r15

    cmp rsi, 2
    jne .smss_error

    mov r14, [rdi]          ; self
    mov r15, [rdi + 16]     ; other

    mov r12, [r14 + PyDictObject.entries]
    mov r13, [r14 + PyDictObject.capacity]
    xor ecx, ecx

.smss_loop:
    cmp rcx, r13
    jge .smss_true

    imul rax, rcx, SET_ENTRY_SIZE
    add rax, r12
    push rcx

    cmp qword [rax + SET_ENTRY_KEY_TAG], 0
    je .smss_next

    mov rdi, r15
    mov rsi, [rax + SET_ENTRY_KEY]
    mov rdx, [rax + SET_ENTRY_KEY_TAG]
    call set_contains
    test eax, eax
    jz .smss_false          ; not in other

.smss_next:
    pop rcx
    inc ecx
    jmp .smss_loop

.smss_true:
    lea rax, [rel bool_true]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.smss_false:
    pop rcx                 ; balance the push in loop
    lea rax, [rel bool_false]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.smss_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "issubset() takes exactly one argument"
    call raise_exception
END_FUNC set_method_issubset

;; ============================================================================
;; set_method_issuperset(args, nargs) -> bool
;; args[0]=self, args[1]=other
;; True if every element of other is in self.
;; ============================================================================
DEF_FUNC set_method_issuperset
    push rbx
    push r12
    push r13
    push r14
    push r15

    cmp rsi, 2
    jne .smis_error

    mov r14, [rdi + 16]     ; other (iterate this)
    mov r15, [rdi]          ; self (check contains)

    mov r12, [r14 + PyDictObject.entries]
    mov r13, [r14 + PyDictObject.capacity]
    xor ecx, ecx

.smis_loop:
    cmp rcx, r13
    jge .smis_true

    imul rax, rcx, SET_ENTRY_SIZE
    add rax, r12
    push rcx

    cmp qword [rax + SET_ENTRY_KEY_TAG], 0
    je .smis_next

    mov rdi, r15            ; check in self
    mov rsi, [rax + SET_ENTRY_KEY]
    mov rdx, [rax + SET_ENTRY_KEY_TAG]
    call set_contains
    test eax, eax
    jz .smis_false

.smis_next:
    pop rcx
    inc ecx
    jmp .smis_loop

.smis_true:
    lea rax, [rel bool_true]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.smis_false:
    pop rcx
    lea rax, [rel bool_false]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.smis_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "issuperset() takes exactly one argument"
    call raise_exception
END_FUNC set_method_issuperset

;; ============================================================================
;; set_method_isdisjoint(args, nargs) -> bool
;; args[0]=self, args[1]=other
;; True if self and other have no common elements.
;; ============================================================================
DEF_FUNC set_method_isdisjoint
    push rbx
    push r12
    push r13
    push r14
    push r15

    cmp rsi, 2
    jne .smdj_error

    mov r14, [rdi]          ; self
    mov r15, [rdi + 16]     ; other

    mov r12, [r14 + PyDictObject.entries]
    mov r13, [r14 + PyDictObject.capacity]
    xor ecx, ecx

.smdj_loop:
    cmp rcx, r13
    jge .smdj_true

    imul rax, rcx, SET_ENTRY_SIZE
    add rax, r12
    push rcx

    cmp qword [rax + SET_ENTRY_KEY_TAG], 0
    je .smdj_next

    mov rdi, r15
    mov rsi, [rax + SET_ENTRY_KEY]
    mov rdx, [rax + SET_ENTRY_KEY_TAG]
    call set_contains
    test eax, eax
    jnz .smdj_false         ; found in other — not disjoint

.smdj_next:
    pop rcx
    inc ecx
    jmp .smdj_loop

.smdj_true:
    lea rax, [rel bool_true]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.smdj_false:
    pop rcx
    lea rax, [rel bool_false]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.smdj_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "isdisjoint() takes exactly one argument"
    call raise_exception
END_FUNC set_method_isdisjoint


;; ############################################################################
;;                       INT METHODS
;; ############################################################################

;; ============================================================================
;; HELPER: int_method_self_to_i64
;; Extract raw i64 from self, handling both SmallInt and heap int (subclasses).
;; Input: rdi = args pointer (args[0] = fat value)
;; Output: rax = raw i64
;; Clobbers: rcx, rdx
;; ============================================================================
DEF_FUNC int_method_self_to_i64
    mov rdx, [rdi + 8]         ; self.tag
    cmp edx, TAG_SMALLINT
    jne .imsi_heap
    mov rax, [rdi]              ; SmallInt payload = raw i64
    leave
    ret
.imsi_heap:
    ; TAG_PTR: heap int (subclass) — use int_to_i64
    mov rdi, [rdi]              ; heap int ptr
    call int_to_i64
    leave
    ret
END_FUNC int_method_self_to_i64

;; ============================================================================
;; int_method_bit_length(args, nargs) -> SmallInt
;; args[0] = self (SmallInt or heap int subclass)
;; Returns number of bits needed to represent abs(self), excluding sign and
;; leading zeros. bit_length(0) = 0.
;; ============================================================================
DEF_FUNC int_method_bit_length
    call int_method_self_to_i64

    ; abs(self)
    mov rcx, rax
    neg rcx
    cmovs rcx, rax              ; rcx = abs(self)

    ; bit_length = 0 for 0
    test rcx, rcx
    jz .ibl_zero

    ; bsr finds highest set bit (0-indexed)
    bsr rax, rcx
    inc rax                     ; bit_length = highest_bit + 1
    RET_TAG_SMALLINT
    leave
    ret

.ibl_zero:
    xor eax, eax
    RET_TAG_SMALLINT
    leave
    ret
END_FUNC int_method_bit_length

;; ============================================================================
;; int_method_bit_count(args, nargs) -> SmallInt
;; Returns number of ones in the binary representation of abs(self).
;; ============================================================================
DEF_FUNC int_method_bit_count
    call int_method_self_to_i64

    ; abs(self)
    mov rcx, rax
    neg rcx
    cmovs rcx, rax              ; rcx = abs(self)

    ; popcnt counts 1 bits
    popcnt rax, rcx
    RET_TAG_SMALLINT
    leave
    ret
END_FUNC int_method_bit_count

;; ============================================================================
;; int_method___index__(args, nargs) -> SmallInt
;; ============================================================================
DEF_FUNC int_method___index__
    call int_method_self_to_i64
    RET_TAG_SMALLINT
    leave
    ret
END_FUNC int_method___index__

;; ============================================================================
;; int_method_conjugate(args, nargs) -> SmallInt
;; ============================================================================
DEF_FUNC int_method_conjugate
    call int_method_self_to_i64
    RET_TAG_SMALLINT
    leave
    ret
END_FUNC int_method_conjugate

;; ============================================================================
;; int_method___abs__(args, nargs) -> SmallInt
;; ============================================================================
DEF_FUNC int_method___abs__
    call int_method_self_to_i64
    mov rcx, rax
    neg rcx
    cmovs rcx, rax              ; rcx = abs(self)
    mov rax, rcx
    RET_TAG_SMALLINT
    leave
    ret
END_FUNC int_method___abs__

;; ============================================================================
;; int_method_to_bytes(args, nargs) -> bytes
;; args[0]=self, args[1]=length, args[2]=byteorder ("big" or "little")
;; Optional kwarg: signed=False (via kw_names_pending)
;; ============================================================================
extern kw_names_pending

ITB_SELF  equ 8
ITB_LEN   equ 16
ITB_SIGN  equ 24
ITB_FRAME equ 32

DEF_FUNC int_method_to_bytes, ITB_FRAME
    push rbx
    push r12

    mov qword [rbp - ITB_SIGN], 0   ; signed = False

    ; Extract self value
    mov rbx, rdi
    call int_method_self_to_i64
    mov [rbp - ITB_SELF], rax       ; self i64

    ; Extract length arg
    mov rdx, [rbx + 24]            ; args[1] tag
    cmp edx, TAG_SMALLINT
    jne .itb_error
    mov r12, [rbx + 16]            ; args[1] payload = length
    mov [rbp - ITB_LEN], r12

    ; Extract byteorder arg
    mov rdx, [rbx + 40]            ; args[2] tag
    mov rcx, [rbx + 32]            ; args[2] payload (str)
    cmp edx, TAG_PTR
    jne .itb_error

    ; Check for "big" or "little"
    ; rcx = byteorder str obj
    push rcx                        ; save for comparison

    ; Compare with "big"
    lea rdi, [rcx + PyStrObject.data]
    CSTRING rsi, "big"
    call ap_strcmp
    pop rcx
    test eax, eax
    jz .itb_big

    push rcx
    lea rdi, [rcx + PyStrObject.data]
    CSTRING rsi, "little"
    call ap_strcmp
    pop rcx
    test eax, eax
    jz .itb_little

    jmp .itb_order_error

.itb_big:
    ; Big-endian: MSB first
    mov rdi, r12                    ; length
    call bytes_new
    mov rbx, rax

    ; Fill from end to start
    mov rax, [rbp - ITB_SELF]
    mov rcx, r12
.itb_big_loop:
    test rcx, rcx
    jz .itb_return
    dec rcx
    mov [rbx + PyBytesObject.data + rcx], al
    shr rax, 8
    jmp .itb_big_loop

.itb_little:
    ; Little-endian: LSB first
    mov rdi, r12
    call bytes_new
    mov rbx, rax

    mov rax, [rbp - ITB_SELF]
    xor ecx, ecx
.itb_little_loop:
    cmp rcx, r12
    jge .itb_return
    mov [rbx + PyBytesObject.data + rcx], al
    shr rax, 8
    inc rcx
    jmp .itb_little_loop

.itb_return:
    mov rax, rbx
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

.itb_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "to_bytes() requires (length, byteorder) arguments"
    call raise_exception

.itb_order_error:
    lea rdi, [rel exc_ValueError_type]
    CSTRING rsi, "byteorder must be 'little' or 'big'"
    call raise_exception
END_FUNC int_method_to_bytes

;; ============================================================================
;; int_classmethod_from_bytes(args, nargs) -> SmallInt
;; args[0]=cls (type), args[1]=bytes, args[2]=byteorder ("big" or "little")
;; This is a classmethod: cls is passed as first arg.
;; ============================================================================
extern classmethod_type

IFB_BYTES equ 8
IFB_FRAME equ 16

DEF_FUNC int_classmethod_from_bytes, IFB_FRAME
    push rbx
    push r12

    ; args[1] = bytes object
    mov rax, [rdi + 16]            ; payload
    mov [rbp - IFB_BYTES], rax

    ; args[2] = byteorder
    mov edx, [rdi + 40]            ; tag
    mov rcx, [rdi + 32]            ; payload
    cmp edx, TAG_PTR
    jne .ifb_error
    push rcx

    lea rdi, [rcx + PyStrObject.data]
    CSTRING rsi, "big"
    call ap_strcmp
    pop rcx
    test eax, eax
    jz .ifb_big

    push rcx
    lea rdi, [rcx + PyStrObject.data]
    CSTRING rsi, "little"
    call ap_strcmp
    pop rcx
    test eax, eax
    jz .ifb_little

    jmp .ifb_order_error

.ifb_big:
    ; Big-endian: MSB first
    mov rax, [rbp - IFB_BYTES]
    mov rcx, [rax + PyBytesObject.ob_size]
    lea rsi, [rax + PyBytesObject.data]
    xor r12, r12                    ; result = 0
    xor edx, edx                   ; index
.ifb_big_loop:
    cmp rdx, rcx
    jge .ifb_return
    shl r12, 8
    movzx eax, byte [rsi + rdx]
    or r12, rax
    inc rdx
    jmp .ifb_big_loop

.ifb_little:
    ; Little-endian: LSB first
    mov rax, [rbp - IFB_BYTES]
    mov rcx, [rax + PyBytesObject.ob_size]
    lea rsi, [rax + PyBytesObject.data]
    xor r12, r12
    mov rdx, rcx
    dec rdx
.ifb_little_loop:
    test rdx, rdx
    js .ifb_return
    shl r12, 8
    movzx eax, byte [rsi + rdx]
    or r12, rax
    dec rdx
    jmp .ifb_little_loop

.ifb_return:
    mov rax, r12
    RET_TAG_SMALLINT
    pop r12
    pop rbx
    leave
    ret

.ifb_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "from_bytes() requires (bytes, byteorder) arguments"
    call raise_exception

.ifb_order_error:
    lea rdi, [rel exc_ValueError_type]
    CSTRING rsi, "byteorder must be 'little' or 'big'"
    call raise_exception
END_FUNC int_classmethod_from_bytes

;; ============================================================================
;; int_method___int__(args, nargs) -> SmallInt
;; ============================================================================
DEF_FUNC int_method___int__
    call int_method_self_to_i64
    RET_TAG_SMALLINT
    leave
    ret
END_FUNC int_method___int__

;; ============================================================================
;; int_method___float__(args, nargs) -> Float
;; ============================================================================
DEF_FUNC int_method___float__
    call int_method_self_to_i64
    cvtsi2sd xmm0, rax
    movq rax, xmm0             ; raw double bits
    mov edx, TAG_FLOAT
    leave
    ret
END_FUNC int_method___float__


;; ############################################################################
;;                       FLOAT METHODS
;; ############################################################################

;; ============================================================================
;; float_method_is_integer(args, nargs) -> Bool
;; args[0] = self (Float: payload=raw double bits, tag=TAG_FLOAT)
;; Returns True if float has no fractional part.
;; ============================================================================
extern float_type

DEF_FUNC float_method_is_integer
    mov rax, [rdi]              ; self.payload = raw double bits
    movq xmm0, rax

    ; Check for inf/nan — not integer
    movq rax, xmm0
    mov rcx, 0x7FF0000000000000  ; inf exponent mask
    and rax, rcx
    cmp rax, rcx
    je .fii_false               ; inf or nan

    ; Compare floor(x) == x
    roundsd xmm1, xmm0, 1      ; xmm1 = floor(xmm0) (round toward -inf)
    ucomisd xmm0, xmm1
    jp .fii_false               ; NaN
    jne .fii_false              ; not equal

    ; True
    mov eax, 1
    mov edx, TAG_BOOL
    leave
    ret

.fii_false:
    xor eax, eax
    mov edx, TAG_BOOL
    leave
    ret
END_FUNC float_method_is_integer

;; ============================================================================
;; float_method_conjugate(args, nargs) -> Float (return self)
;; ============================================================================
DEF_FUNC_BARE float_method_conjugate
    mov rax, [rdi]              ; self.payload = raw double bits
    mov edx, TAG_FLOAT
    ret
END_FUNC float_method_conjugate

;; ============================================================================
;; float_method___int__(args, nargs) -> SmallInt
;; ============================================================================
DEF_FUNC_BARE float_method___int__
    mov rax, [rdi]              ; self.payload = raw double bits
    movq xmm0, rax
    cvttsd2si rax, xmm0        ; truncate to i64
    mov edx, TAG_SMALLINT
    ret
END_FUNC float_method___int__

;; ============================================================================
;; float_method___float__(args, nargs) -> Float (return self)
;; ============================================================================
DEF_FUNC_BARE float_method___float__
    mov rax, [rdi]              ; self.payload = raw double bits
    mov edx, TAG_FLOAT
    ret
END_FUNC float_method___float__

;; ============================================================================
;; float_method___trunc__(args, nargs) -> SmallInt
;; ============================================================================
DEF_FUNC_BARE float_method___trunc__
    mov rax, [rdi]              ; self.payload = raw double bits
    movq xmm0, rax
    cvttsd2si rax, xmm0        ; truncate to i64
    mov edx, TAG_SMALLINT
    ret
END_FUNC float_method___trunc__

;; ============================================================================
;; float_method___abs__(args, nargs) -> Float
;; ============================================================================
DEF_FUNC_BARE float_method___abs__
    mov rax, [rdi]              ; self.payload = raw double bits
    btr rax, 63                 ; clear sign bit
    mov edx, TAG_FLOAT
    ret
END_FUNC float_method___abs__


;; ############################################################################
;;                       BYTES METHODS
;; ############################################################################

;; ============================================================================
;; bytes_method_hex(args, nargs) -> str
;; Converts bytes to hex string like b'\xab\xcd'.hex() -> 'abcd'
;; ============================================================================
extern bytes_type
BH_SELF   equ 8
BH_BUF    equ 16
BH_HEXLEN equ 24
BH_FRAME  equ 32

DEF_FUNC bytes_method_hex, BH_FRAME
    mov rax, [rdi]              ; self = bytes obj ptr
    mov [rbp - BH_SELF], rax

    ; Get length
    mov rcx, [rax + PyBytesObject.ob_size]
    test rcx, rcx
    jz .bh_empty

    ; Allocate temp buffer for hex chars: 2 chars per byte
    lea rdi, [rcx * 2]
    mov [rbp - BH_HEXLEN], rdi
    call ap_malloc
    mov [rbp - BH_BUF], rax

    ; Fill hex chars into temp buffer
    mov rdx, [rbp - BH_SELF]
    mov rdi, rax                ; dest = temp buf
    lea rsi, [rdx + PyBytesObject.data]
    mov rcx, [rdx + PyBytesObject.ob_size]
    xor r8d, r8d                ; byte index

.bh_loop:
    cmp r8, rcx
    jge .bh_done
    movzx eax, byte [rsi + r8]

    ; High nibble
    mov r9d, eax
    shr r9d, 4
    cmp r9d, 10
    jb .bh_hi_digit
    add r9d, ('a' - 10)
    jmp .bh_hi_store
.bh_hi_digit:
    add r9d, '0'
.bh_hi_store:
    mov [rdi], r9b
    inc rdi

    ; Low nibble
    and eax, 0x0F
    cmp eax, 10
    jb .bh_lo_digit
    add eax, ('a' - 10)
    jmp .bh_lo_store
.bh_lo_digit:
    add eax, '0'
.bh_lo_store:
    mov [rdi], al
    inc rdi

    inc r8
    jmp .bh_loop

.bh_done:
    ; Create string from temp buffer
    mov rdi, [rbp - BH_BUF]
    mov rsi, [rbp - BH_HEXLEN]
    call str_new_heap
    push rax                    ; save result

    ; Free temp buffer
    mov rdi, [rbp - BH_BUF]
    call ap_free

    pop rax
    mov edx, TAG_PTR
    leave
    ret

.bh_empty:
    ; Return empty string
    lea rdi, [rel empty_str_cstr]
    xor esi, esi                ; length = 0
    call str_new_heap
    mov edx, TAG_PTR
    leave
    ret
END_FUNC bytes_method_hex

;; ============================================================================
;; bytes_method_startswith(args, nargs) -> Bool
;; args[0]=self (bytes), args[1]=prefix (bytes)
;; ============================================================================
DEF_FUNC bytes_method_startswith
    cmp rsi, 2
    jne .bsw_error

    mov rax, [rdi]              ; self
    mov rcx, [rdi + 16]         ; prefix

    ; Get lengths
    mov r8, [rax + PyBytesObject.ob_size]   ; self len
    mov r9, [rcx + PyBytesObject.ob_size]   ; prefix len

    ; If prefix longer than self: False
    cmp r9, r8
    ja .bsw_false

    ; Compare first r9 bytes
    lea rdi, [rax + PyBytesObject.data]
    lea rsi, [rcx + PyBytesObject.data]
    mov rdx, r9
    test rdx, rdx
    jz .bsw_true                ; empty prefix always matches
    call ap_memcmp
    test eax, eax
    jnz .bsw_false

.bsw_true:
    mov eax, 1
    mov edx, TAG_BOOL
    leave
    ret

.bsw_false:
    xor eax, eax
    mov edx, TAG_BOOL
    leave
    ret

.bsw_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "startswith() takes exactly one argument"
    call raise_exception
END_FUNC bytes_method_startswith

;; ============================================================================
;; bytes_method_endswith(args, nargs) -> Bool
;; args[0]=self (bytes), args[1]=suffix (bytes)
;; ============================================================================
DEF_FUNC bytes_method_endswith
    cmp rsi, 2
    jne .bew_error

    mov rax, [rdi]              ; self
    mov rcx, [rdi + 16]         ; suffix

    ; Get lengths
    mov r8, [rax + PyBytesObject.ob_size]   ; self len
    mov r9, [rcx + PyBytesObject.ob_size]   ; suffix len

    ; If suffix longer than self: False
    cmp r9, r8
    ja .bew_false

    ; Compare last r9 bytes
    mov rdx, r8
    sub rdx, r9                             ; offset = self_len - suffix_len
    lea rdi, [rax + PyBytesObject.data + rdx]
    lea rsi, [rcx + PyBytesObject.data]
    mov rdx, r9
    test rdx, rdx
    jz .bew_true                ; empty suffix always matches
    call ap_memcmp
    test eax, eax
    jnz .bew_false

.bew_true:
    mov eax, 1
    mov edx, TAG_BOOL
    leave
    ret

.bew_false:
    xor eax, eax
    mov edx, TAG_BOOL
    leave
    ret

.bew_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "endswith() takes exactly one argument"
    call raise_exception
END_FUNC bytes_method_endswith

;; ============================================================================
;; bytes_method_count(args, nargs) -> SmallInt
;; args[0]=self (bytes), args[1]=sub (bytes)
;; Count non-overlapping occurrences of sub in self.
;; ============================================================================
BC_SELF   equ 8
BC_SUB    equ 16
BC_FRAME  equ 24

DEF_FUNC bytes_method_count, BC_FRAME
    cmp rsi, 2
    jne .bc_error

    mov rax, [rdi]              ; self
    mov rcx, [rdi + 16]         ; sub
    mov [rbp - BC_SELF], rax
    mov [rbp - BC_SUB], rcx

    mov r8, [rax + PyBytesObject.ob_size]   ; self_len
    mov r9, [rcx + PyBytesObject.ob_size]   ; sub_len

    ; If sub_len == 0: count = self_len + 1
    test r9, r9
    jz .bc_empty_sub

    ; If sub_len > self_len: count = 0
    cmp r9, r8
    ja .bc_zero

    ; Scan
    xor r10d, r10d              ; count = 0
    xor r11d, r11d              ; offset = 0

.bc_loop:
    mov rax, r8
    sub rax, r11                ; remaining = self_len - offset
    cmp rax, r9
    jb .bc_result               ; not enough bytes left

    mov rdi, [rbp - BC_SELF]
    lea rdi, [rdi + PyBytesObject.data + r11]
    mov rsi, [rbp - BC_SUB]
    lea rsi, [rsi + PyBytesObject.data]
    mov rdx, r9
    push r8
    push r9
    push r10
    push r11
    call ap_memcmp
    pop r11
    pop r10
    pop r9
    pop r8
    test eax, eax
    jnz .bc_nomatch

    ; Match found
    inc r10
    add r11, r9                 ; skip sub_len (non-overlapping)
    jmp .bc_loop

.bc_nomatch:
    inc r11
    jmp .bc_loop

.bc_result:
    mov rax, r10
    RET_TAG_SMALLINT
    leave
    ret

.bc_empty_sub:
    lea rax, [r8 + 1]
    RET_TAG_SMALLINT
    leave
    ret

.bc_zero:
    xor eax, eax
    RET_TAG_SMALLINT
    leave
    ret

.bc_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "count() takes exactly one argument"
    call raise_exception
END_FUNC bytes_method_count

;; ============================================================================
;; bytes_method_find(args, nargs) -> SmallInt
;; args[0]=self (bytes), args[1]=sub (bytes)
;; Returns index of first occurrence, or -1 if not found.
;; ============================================================================
BF_SELF   equ 8
BF_SUB    equ 16
BF_FRAME  equ 24

DEF_FUNC bytes_method_find, BF_FRAME
    cmp rsi, 2
    jne .bf_error

    mov rax, [rdi]              ; self
    mov rcx, [rdi + 16]         ; sub
    mov [rbp - BF_SELF], rax
    mov [rbp - BF_SUB], rcx

    mov r8, [rax + PyBytesObject.ob_size]   ; self_len
    mov r9, [rcx + PyBytesObject.ob_size]   ; sub_len

    ; If sub_len == 0: return 0
    test r9, r9
    jz .bf_found_zero

    ; If sub_len > self_len: return -1
    cmp r9, r8
    ja .bf_not_found

    ; Scan
    xor r11d, r11d              ; offset = 0

.bf_loop:
    mov rax, r8
    sub rax, r11                ; remaining
    cmp rax, r9
    jb .bf_not_found

    mov rdi, [rbp - BF_SELF]
    lea rdi, [rdi + PyBytesObject.data + r11]
    mov rsi, [rbp - BF_SUB]
    lea rsi, [rsi + PyBytesObject.data]
    mov rdx, r9
    push r8
    push r9
    push r11
    call ap_memcmp
    pop r11
    pop r9
    pop r8
    test eax, eax
    jz .bf_found

    inc r11
    jmp .bf_loop

.bf_found:
    mov rax, r11
    RET_TAG_SMALLINT
    leave
    ret

.bf_found_zero:
    xor eax, eax
    RET_TAG_SMALLINT
    leave
    ret

.bf_not_found:
    mov rax, -1
    RET_TAG_SMALLINT
    leave
    ret

.bf_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "find() takes exactly one argument"
    call raise_exception
END_FUNC bytes_method_find

;; ============================================================================
;; bytes_method_replace(args, nargs) -> new bytes
;; args[0]=self (bytes), args[1]=old (bytes), args[2]=new (bytes)
;; Scan self for old subsequence, build new PyBytesObject with replacements.
;; ============================================================================
extern bytes_new
extern bytes_from_data

BR_SELF   equ 8
BR_OLD    equ 16
BR_NEW    equ 24
BR_BUF    equ 32
BR_BUFSZ  equ 40
BR_WPOS   equ 48
BR_FRAME  equ 56

DEF_FUNC bytes_method_replace, BR_FRAME
    push rbx
    push r12
    push r13
    push r14
    push r15

    cmp rsi, 3
    jne .br_error

    mov rax, [rdi]              ; self
    mov rcx, [rdi + 16]         ; old
    mov rdx, [rdi + 32]         ; new
    mov [rbp - BR_SELF], rax
    mov [rbp - BR_OLD], rcx
    mov [rbp - BR_NEW], rdx

    ; rbx=self, r12=old, r13=new
    mov rbx, rax
    mov r12, rcx
    mov r13, rdx

    mov r14, [rbx + PyBytesObject.ob_size]    ; self_len
    mov r15, [r12 + PyBytesObject.ob_size]    ; old_len

    ; If old_len == 0, return copy of self
    test r15, r15
    jz .br_copy_self

    ; Allocate initial buffer: self_len * 2 + 64
    lea rdi, [r14 * 2 + 64]
    mov [rbp - BR_BUFSZ], rdi
    call ap_malloc
    mov [rbp - BR_BUF], rax
    mov qword [rbp - BR_WPOS], 0

    xor ecx, ecx               ; scan position

.br_scan:
    ; Remaining bytes
    mov rax, r14
    sub rax, rcx
    cmp rax, r15
    jl .br_copy_tail

    ; memcmp at scan position
    push rcx
    mov rdi, [rbp - BR_SELF]
    lea rdi, [rdi + PyBytesObject.data]
    add rdi, rcx
    mov rsi, [rbp - BR_OLD]
    lea rsi, [rsi + PyBytesObject.data]
    mov rdx, r15
    call ap_memcmp
    pop rcx
    test eax, eax
    jnz .br_no_match

    ; Match found at rcx — ensure buffer space
    mov rax, [rbp - BR_WPOS]
    add rax, [r13 + PyBytesObject.ob_size]
    add rax, r14
    cmp rax, [rbp - BR_BUFSZ]
    jl .br_space_ok
    shl rax, 1
    mov [rbp - BR_BUFSZ], rax
    push rcx
    mov rdi, [rbp - BR_BUF]
    mov rsi, rax
    call ap_realloc
    mov [rbp - BR_BUF], rax
    pop rcx
.br_space_ok:

    ; Copy new_str into buffer
    mov rax, [r13 + PyBytesObject.ob_size]
    test rax, rax
    jz .br_skip_new
    push rcx
    push rax
    mov rdi, [rbp - BR_BUF]
    add rdi, [rbp - BR_WPOS]
    mov rsi, [rbp - BR_NEW]
    lea rsi, [rsi + PyBytesObject.data]
    mov rdx, rax
    call ap_memcpy
    pop rax
    pop rcx
    add [rbp - BR_WPOS], rax
.br_skip_new:
    add rcx, r15                ; advance past old
    jmp .br_scan

.br_no_match:
    ; Copy one byte from self
    mov rdi, [rbp - BR_BUF]
    add rdi, [rbp - BR_WPOS]
    mov rax, [rbp - BR_SELF]
    movzx eax, byte [rax + PyBytesObject.data + rcx]
    mov [rdi], al
    inc qword [rbp - BR_WPOS]
    inc rcx
    jmp .br_scan

.br_copy_tail:
    ; Copy remaining bytes
    mov rax, r14
    sub rax, rcx
    test rax, rax
    jz .br_make_bytes
    push rax
    push rcx
    mov rdi, [rbp - BR_BUF]
    add rdi, [rbp - BR_WPOS]
    mov rsi, [rbp - BR_SELF]
    lea rsi, [rsi + PyBytesObject.data]
    add rsi, rcx
    mov rdx, rax
    call ap_memcpy
    pop rcx
    pop rax
    add [rbp - BR_WPOS], rax

.br_make_bytes:
    mov rdi, [rbp - BR_BUF]
    mov rsi, [rbp - BR_WPOS]
    call bytes_from_data
    push rax

    mov rdi, [rbp - BR_BUF]
    call ap_free

    pop rax
    mov edx, TAG_PTR
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.br_copy_self:
    ; Return copy of self
    lea rdi, [rbx + PyBytesObject.data]
    mov rsi, r14
    call bytes_from_data
    mov edx, TAG_PTR
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.br_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "replace() takes exactly 2 arguments"
    call raise_exception
END_FUNC bytes_method_replace

;; ============================================================================
;; bytes_method_split(args, nargs) -> list of bytes
;; nargs==1: split by whitespace; nargs==2: split by separator bytes
;; ============================================================================
DEF_FUNC bytes_method_split
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8                  ; align

    mov rbx, [rdi]              ; self (bytes obj)
    mov r14, rsi                ; nargs

    cmp r14, 2
    jl .bsp_no_sep

    ; Separator mode
    mov r15, [rdi + 16]         ; separator bytes obj
    jmp .bsp_by_sep

.bsp_no_sep:
    ; Split by whitespace
    mov r12, [rbx + PyBytesObject.ob_size]

    mov rdi, 8
    call list_new
    mov r13, rax                ; result list

    xor ecx, ecx
.bsp_ws_scan:
    cmp rcx, r12
    jge .bsp_ws_done
    movzx eax, byte [rbx + PyBytesObject.data + rcx]
    cmp al, ' '
    je .bsp_ws_skip
    cmp al, 9
    je .bsp_ws_skip
    cmp al, 10
    je .bsp_ws_skip
    cmp al, 13
    je .bsp_ws_skip
    jmp .bsp_ws_word

.bsp_ws_skip:
    inc rcx
    jmp .bsp_ws_scan

.bsp_ws_word:
    mov r15, rcx                ; word start
.bsp_ws_wordscan:
    inc rcx
    cmp rcx, r12
    jge .bsp_ws_wordend
    movzx eax, byte [rbx + PyBytesObject.data + rcx]
    cmp al, ' '
    je .bsp_ws_wordend
    cmp al, 9
    je .bsp_ws_wordend
    cmp al, 10
    je .bsp_ws_wordend
    cmp al, 13
    je .bsp_ws_wordend
    jmp .bsp_ws_wordscan

.bsp_ws_wordend:
    push rcx
    lea rdi, [rbx + PyBytesObject.data]
    add rdi, r15
    mov rsi, rcx
    sub rsi, r15
    call bytes_from_data
    mov rdi, r13
    mov rsi, rax
    push rax
    mov edx, TAG_PTR
    call list_append
    pop rdi
    call obj_decref
    pop rcx
    jmp .bsp_ws_scan

.bsp_ws_done:
    mov rax, r13
    mov edx, TAG_PTR
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.bsp_by_sep:
    mov r12, [rbx + PyBytesObject.ob_size]   ; self_len
    mov r14, [r15 + PyBytesObject.ob_size]   ; sep_len

    mov rdi, 8
    call list_new
    mov r13, rax                ; result list

    test r14, r14
    jz .bsp_empty_sep

    ; r11 = segment start, rcx = scan position
    xor ecx, ecx
    xor r11d, r11d              ; segment start = 0

.bsp_sep_scan:
    ; Check if enough bytes remain for separator
    mov rax, r12
    sub rax, rcx
    cmp rax, r14
    jl .bsp_sep_tail

    ; memcmp at scan position
    push rcx
    push r11
    mov rdi, rbx
    lea rdi, [rdi + PyBytesObject.data]
    add rdi, rcx
    lea rsi, [r15 + PyBytesObject.data]
    mov rdx, r14
    call ap_memcmp
    pop r11
    pop rcx
    test eax, eax
    jnz .bsp_sep_nomatch

    ; Found separator at rcx — extract segment [r11..rcx)
    push rcx
    push r11
    lea rdi, [rbx + PyBytesObject.data]
    add rdi, r11
    mov rsi, rcx
    sub rsi, r11
    call bytes_from_data
    mov rdi, r13
    mov rsi, rax
    push rax
    mov edx, TAG_PTR
    call list_append
    pop rdi
    call obj_decref
    pop r11
    pop rcx

    ; Advance past separator
    add rcx, r14
    mov r11, rcx               ; new segment start
    jmp .bsp_sep_scan

.bsp_sep_nomatch:
    inc rcx
    jmp .bsp_sep_scan

.bsp_sep_tail:
    ; Remaining segment from r11 to end
    lea rdi, [rbx + PyBytesObject.data]
    add rdi, r11
    mov rsi, r12
    sub rsi, r11
    call bytes_from_data
    mov rdi, r13
    mov rsi, rax
    push rax
    mov edx, TAG_PTR
    call list_append
    pop rdi
    call obj_decref

    mov rax, r13
    mov edx, TAG_PTR
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.bsp_empty_sep:
    lea rdi, [rel exc_ValueError_type]
    CSTRING rsi, "empty separator"
    call raise_exception
END_FUNC bytes_method_split

;; ============================================================================
;; bytes_method_join(args, nargs) -> new bytes
;; args[0]=self (separator bytes), args[1]=list
;; ============================================================================
BJ_SEP    equ 8
BJ_LIST   equ 16
BJ_TOTAL  equ 24
BJ_BUF    equ 32
BJ_WPOS   equ 40
BJ_FRAME  equ 48

DEF_FUNC bytes_method_join, BJ_FRAME
    push rbx
    push r12
    push r13
    push r14
    push r15

    cmp rsi, 2
    jne .bj_error

    mov rax, [rdi]              ; self = separator bytes
    mov rcx, [rdi + 16]         ; list
    mov [rbp - BJ_SEP], rax
    mov [rbp - BJ_LIST], rcx

    ; Check list type
    mov rdx, [rcx + PyObject.ob_type]
    lea r8, [rel list_type]
    cmp rdx, r8
    jne .bj_error

    ; Get count
    mov r12, [rcx + PyListObject.ob_size]   ; count
    test r12, r12
    jz .bj_empty

    ; Compute total length: sum of all item sizes + (count-1)*sep_len
    mov rbx, [rbp - BJ_SEP]
    mov r14, [rbx + PyBytesObject.ob_size]  ; sep_len

    xor r13d, r13d              ; total = 0
    xor ecx, ecx               ; index = 0
.bj_len_loop:
    cmp rcx, r12
    jge .bj_len_done
    mov rax, [rbp - BJ_LIST]
    mov rax, [rax + PyListObject.ob_item]
    mov rax, [rax + rcx * 8]  ; item payload (8-byte stride)
    add r13, [rax + PyBytesObject.ob_size]
    inc rcx
    jmp .bj_len_loop
.bj_len_done:
    ; Add separator lengths: (count-1) * sep_len
    mov rax, r12
    dec rax
    imul rax, r14
    add r13, rax
    mov [rbp - BJ_TOTAL], r13

    ; Allocate buffer
    mov rdi, r13
    call ap_malloc
    mov [rbp - BJ_BUF], rax
    mov qword [rbp - BJ_WPOS], 0

    ; Copy data
    xor r15d, r15d              ; item index
.bj_copy_loop:
    cmp r15, r12
    jge .bj_make_bytes

    ; Insert separator before all items except first
    test r15, r15
    jz .bj_no_sep
    mov rax, [rbp - BJ_SEP]
    mov rcx, [rax + PyBytesObject.ob_size]
    test rcx, rcx
    jz .bj_no_sep
    push rcx
    mov rdi, [rbp - BJ_BUF]
    add rdi, [rbp - BJ_WPOS]
    lea rsi, [rax + PyBytesObject.data]
    mov rdx, rcx
    call ap_memcpy
    pop rcx
    add [rbp - BJ_WPOS], rcx
.bj_no_sep:
    ; Copy item bytes
    mov rax, [rbp - BJ_LIST]
    mov rax, [rax + PyListObject.ob_item]
    mov rax, [rax + r15 * 8]  ; item bytes obj (8-byte stride)
    mov rcx, [rax + PyBytesObject.ob_size]
    test rcx, rcx
    jz .bj_next_item
    push rcx
    mov rdi, [rbp - BJ_BUF]
    add rdi, [rbp - BJ_WPOS]
    lea rsi, [rax + PyBytesObject.data]
    mov rdx, rcx
    call ap_memcpy
    pop rcx
    add [rbp - BJ_WPOS], rcx
.bj_next_item:
    inc r15
    jmp .bj_copy_loop

.bj_make_bytes:
    mov rdi, [rbp - BJ_BUF]
    mov rsi, [rbp - BJ_TOTAL]
    call bytes_from_data
    push rax

    mov rdi, [rbp - BJ_BUF]
    call ap_free

    pop rax
    mov edx, TAG_PTR
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.bj_empty:
    ; Return empty bytes
    xor edi, edi
    call bytes_new
    mov edx, TAG_PTR
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.bj_error:
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "join() argument must be a list of bytes"
    call raise_exception
END_FUNC bytes_method_join

;; ============================================================================
;; float_method_as_integer_ratio(args, nargs) -> 2-tuple (numerator, denominator)
;; Extract IEEE 754 mantissa/exponent and return (n, d) as SmallInts.
;; ============================================================================
extern exc_OverflowError_type

FIR_FRAME equ 8
DEF_FUNC float_method_as_integer_ratio, FIR_FRAME
    push rbx

    mov rax, [rdi]              ; self.payload = raw double bits

    ; Check for inf/nan
    mov rcx, rax
    mov rdx, 0x7FF0000000000000
    and rcx, rdx
    cmp rcx, rdx
    je .fir_error

    ; Check for zero
    mov rcx, rax
    btr rcx, 63                 ; clear sign
    test rcx, rcx
    jz .fir_zero

    ; Extract sign, exponent, mantissa from IEEE 754
    ; sign = bit 63, exponent = bits 62-52 (biased), mantissa = bits 51-0
    mov r8, rax                 ; save original bits
    mov rcx, rax
    shr rcx, 52
    and ecx, 0x7FF              ; biased exponent
    sub ecx, 1023               ; unbiased exponent
    sub ecx, 52                 ; adjust for mantissa bits

    ; mantissa with implicit 1 bit
    mov rax, r8
    mov rdx, 0x000FFFFFFFFFFFFF
    and rax, rdx
    bts rax, 52                 ; set implicit bit (bit 52)

    ; Reduce: strip trailing zeros from mantissa (common factor of 2)
    ; This makes the fraction fully reduced
    tzcnt rdx, rax              ; count trailing zeros
    mov cl, dl
    shr rax, cl                 ; mantissa >>= trailing_zeros

    ; Reload exponent (ecx was clobbered by cl usage)
    mov rcx, r8
    shr rcx, 52
    and ecx, 0x7FF
    sub ecx, 1023
    sub ecx, 52
    add ecx, edx               ; adjust exponent by trailing zeros stripped

    ; Apply sign
    bt r8, 63
    jnc .fir_positive
    neg rax
.fir_positive:

    ; Now: value = rax * 2^ecx
    ; If ecx >= 0: numerator = rax << ecx, denominator = 1
    ; If ecx < 0: numerator = rax, denominator = 1 << (-ecx)
    test ecx, ecx
    js .fir_neg_exp

    ; Positive exponent: shift numerator left
    cmp ecx, 62                 ; limit to prevent overflow
    ja .fir_error
    mov cl, cl
    shl rax, cl
    push rax                    ; numerator

    ; Build 2-tuple (numerator=rax, denominator=1)
    mov rdi, 2
    call tuple_new
    mov rbx, rax
    pop rcx                     ; numerator

    mov r9, [rbx + PyTupleObject.ob_item]
    mov r10, [rbx + PyTupleObject.ob_item_tags]
    mov [r9], rcx
    mov byte [r10], TAG_SMALLINT
    mov qword [r9 + 8], 1
    mov byte [r10 + 1], TAG_SMALLINT

    mov rax, rbx
    mov edx, TAG_PTR
    pop rbx
    leave
    ret

.fir_neg_exp:
    ; Negative exponent
    neg ecx
    cmp ecx, 62
    ja .fir_error
    push rax                    ; save numerator
    mov rdx, 1
    shl rdx, cl                 ; denominator = 1 << (-ecx)
    push rdx                    ; save denominator

    mov rdi, 2
    call tuple_new
    mov rbx, rax
    pop rdx                     ; denominator
    pop rcx                     ; numerator

    mov r9, [rbx + PyTupleObject.ob_item]
    mov r10, [rbx + PyTupleObject.ob_item_tags]
    mov [r9], rcx
    mov byte [r10], TAG_SMALLINT
    mov [r9 + 8], rdx
    mov byte [r10 + 1], TAG_SMALLINT

    mov rax, rbx
    mov edx, TAG_PTR
    pop rbx
    leave
    ret

.fir_zero:
    ; Return (0, 1)
    mov rdi, 2
    call tuple_new
    mov rbx, rax

    mov r9, [rbx + PyTupleObject.ob_item]
    mov r10, [rbx + PyTupleObject.ob_item_tags]
    mov qword [r9], 0
    mov byte [r10], TAG_SMALLINT
    mov qword [r9 + 8], 1
    mov byte [r10 + 1], TAG_SMALLINT

    mov rax, rbx
    mov edx, TAG_PTR
    pop rbx
    leave
    ret

.fir_error:
    lea rdi, [rel exc_OverflowError_type]
    CSTRING rsi, "cannot convert float infinity or NaN to integer ratio"
    call raise_exception
END_FUNC float_method_as_integer_ratio

;; ============================================================================
;; float_method_hex(args, nargs) -> str
;; Format double as '0x1.XXXXp+YY' hex string.
;; ============================================================================
FH_BUF    equ 8
FH_FRAME  equ 16

DEF_FUNC float_method_hex, FH_FRAME
    push rbx
    push r12

    mov rax, [rdi]              ; self.payload = raw double bits
    mov rbx, rax                ; save bits

    ; Allocate temp buffer (64 bytes is enough for any hex float)
    mov edi, 64
    call ap_malloc
    mov [rbp - FH_BUF], rax
    mov r12, rax                ; write pointer

    ; Check sign
    bt rbx, 63
    jnc .fh_nosign
    mov byte [r12], '-'
    inc r12
.fh_nosign:

    ; Clear sign for analysis
    mov rax, rbx
    btr rax, 63

    ; Check for zero
    test rax, rax
    jz .fh_zero

    ; Check for inf
    mov rcx, 0x7FF0000000000000
    cmp rax, rcx
    je .fh_inf

    ; Check for NaN
    mov rdx, rax
    and rdx, rcx
    cmp rdx, rcx
    je .fh_nan

    ; Normal float: extract exponent and mantissa
    mov rdx, rax
    shr rdx, 52
    and edx, 0x7FF              ; biased exponent
    sub edx, 1023               ; unbiased

    mov rcx, rax
    mov r8, 0x000FFFFFFFFFFFFF
    and rcx, r8                 ; mantissa bits (52 bits)

    ; Write "0x1."
    mov byte [r12], '0'
    mov byte [r12+1], 'x'
    mov byte [r12+2], '1'
    mov byte [r12+3], '.'
    add r12, 4

    ; Convert mantissa to 13 hex digits (52 bits / 4 = 13 digits)
    ; Write hex digits from high nibble to low
    mov rax, rcx
    mov ecx, 13                 ; 13 hex digits
    mov r8d, 48                 ; shift = 48 (start from high)
.fh_hex_loop:
    test ecx, ecx
    jz .fh_hex_done
    push rcx
    mov cl, r8b
    mov rdx, rax
    shr rdx, cl
    and edx, 0x0F
    pop rcx
    cmp edx, 10
    jb .fh_digit
    add edx, ('a' - 10)
    jmp .fh_store_digit
.fh_digit:
    add edx, '0'
.fh_store_digit:
    mov [r12], dl
    inc r12
    sub r8d, 4
    dec ecx
    jmp .fh_hex_loop

.fh_hex_done:

    ; Write 'p' and exponent
    mov byte [r12], 'p'
    inc r12

    ; edx = unbiased exponent (stored in [rsp area])
    ; We need to reload it; it was in edx before hex loop
    ; Actually we lost edx. Let's recompute.
    mov rax, rbx
    btr rax, 63
    shr rax, 52
    and eax, 0x7FF
    sub eax, 1023

    ; Write sign of exponent
    test eax, eax
    js .fh_exp_neg
    mov byte [r12], '+'
    inc r12
    jmp .fh_exp_write
.fh_exp_neg:
    mov byte [r12], '-'
    inc r12
    neg eax
.fh_exp_write:
    ; Convert exponent to decimal string
    ; eax = absolute exponent value
    ; Use simple div loop
    push r12                    ; save start of exponent digits
    mov ecx, 10
    xor r8d, r8d               ; digit count
    test eax, eax
    jnz .fh_exp_digits
    ; Zero exponent
    mov byte [r12], '0'
    inc r12
    jmp .fh_exp_done
.fh_exp_digits:
    ; Push digits in reverse
    xor edx, edx
    div ecx                     ; eax = quotient, edx = remainder
    push rdx
    inc r8d
    test eax, eax
    jnz .fh_exp_digits
    ; Pop digits into buffer
.fh_exp_pop:
    test r8d, r8d
    jz .fh_exp_done
    pop rax
    add eax, '0'
    mov [r12], al
    inc r12
    dec r8d
    jmp .fh_exp_pop
.fh_exp_done:
    pop rax                     ; discard saved start pos

    ; Create string from buffer
    mov rdi, [rbp - FH_BUF]
    mov rsi, r12
    sub rsi, rdi                ; length
    call str_new_heap
    push rax

    mov rdi, [rbp - FH_BUF]
    call ap_free

    pop rax
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

.fh_zero:
    ; Write "0x0.0p+0"
    mov byte [r12], '0'
    mov byte [r12+1], 'x'
    mov byte [r12+2], '0'
    mov byte [r12+3], '.'
    mov byte [r12+4], '0'
    mov byte [r12+5], 'p'
    mov byte [r12+6], '+'
    mov byte [r12+7], '0'
    add r12, 8
    jmp .fh_make_str

.fh_inf:
    mov byte [r12], 'i'
    mov byte [r12+1], 'n'
    mov byte [r12+2], 'f'
    add r12, 3
    jmp .fh_make_str

.fh_nan:
    mov byte [r12], 'n'
    mov byte [r12+1], 'a'
    mov byte [r12+2], 'n'
    add r12, 3

.fh_make_str:
    mov rdi, [rbp - FH_BUF]
    mov rsi, r12
    sub rsi, rdi
    call str_new_heap
    push rax

    mov rdi, [rbp - FH_BUF]
    call ap_free

    pop rax
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret
END_FUNC float_method_hex

;; ============================================================================
;; float_classmethod_fromhex(args, nargs) -> Float
;; args[0]=cls (type), args[1]=hex string like "0x1.XXXXp+YY"
;; Parses hex float string and returns TAG_FLOAT.
;; ============================================================================
FFH_STR   equ 8
FFH_FRAME equ 16

DEF_FUNC float_classmethod_fromhex, FFH_FRAME
    push rbx
    push r12
    push r13

    ; Get string arg
    mov rcx, [rdi + 16]            ; args[1] payload
    mov [rbp - FFH_STR], rcx
    lea r12, [rcx + PyStrObject.data]  ; r12 = string data

    ; Parse: optional '-', '0x', mantissa '1.XXXX', 'p', exponent
    xor r13d, r13d                  ; r13 = sign (0 = positive)
    xor ebx, ebx                   ; current position

    ; Check for sign
    movzx eax, byte [r12]
    cmp al, '-'
    jne .ffh_check_plus
    mov r13d, 1
    inc ebx
    jmp .ffh_check_0x
.ffh_check_plus:
    cmp al, '+'
    jne .ffh_check_0x
    inc ebx

.ffh_check_0x:
    ; Expect '0x' or '0X'
    cmp byte [r12 + rbx], '0'
    jne .ffh_parse_error
    inc ebx
    movzx eax, byte [r12 + rbx]
    or al, 0x20                     ; lowercase
    cmp al, 'x'
    jne .ffh_parse_error
    inc ebx

    ; Parse integer part (digits before '.')
    xor ecx, ecx                   ; mantissa = 0 (as integer, shifted later)
    ; Parse hex digits
.ffh_int_digits:
    movzx eax, byte [r12 + rbx]
    call .ffh_hex_val               ; eax = hex value or -1
    cmp eax, -1
    je .ffh_int_done
    shl rcx, 4
    or rcx, rax
    inc ebx
    jmp .ffh_int_digits
.ffh_int_done:

    ; Check for '.'
    xor r8d, r8d                    ; frac_bits = 0 (count of hex digits after .)
    cmp byte [r12 + rbx], '.'
    jne .ffh_check_p
    inc ebx

    ; Parse fractional hex digits
.ffh_frac_digits:
    movzx eax, byte [r12 + rbx]
    push rcx
    push r8
    call .ffh_hex_val
    pop r8
    pop rcx
    cmp eax, -1
    je .ffh_check_p
    shl rcx, 4
    or rcx, rax
    inc r8d
    inc ebx
    jmp .ffh_frac_digits

.ffh_check_p:
    ; rcx = combined mantissa, r8d = fractional hex digits
    ; Expect 'p' or 'P'
    movzx eax, byte [r12 + rbx]
    or al, 0x20
    cmp al, 'p'
    jne .ffh_parse_error
    inc ebx

    ; Parse exponent (decimal, with optional sign)
    xor r9d, r9d                    ; exp_sign = 0
    movzx eax, byte [r12 + rbx]
    cmp al, '-'
    jne .ffh_exp_check_plus
    mov r9d, 1
    inc ebx
    jmp .ffh_exp_digits
.ffh_exp_check_plus:
    cmp al, '+'
    jne .ffh_exp_digits
    inc ebx

.ffh_exp_digits:
    xor r10d, r10d                  ; exponent value
.ffh_exp_loop:
    movzx eax, byte [r12 + rbx]
    sub al, '0'
    cmp al, 9
    ja .ffh_exp_done
    imul r10d, 10
    movzx eax, al
    add r10d, eax
    inc ebx
    jmp .ffh_exp_loop
.ffh_exp_done:
    test r9d, r9d
    jz .ffh_compute
    neg r10d

.ffh_compute:
    ; rcx = mantissa bits, r8d = fractional hex digits, r10d = exponent
    ; Actual exponent = r10d - (r8d * 4)  [each hex digit = 4 bits]
    mov eax, r8d
    shl eax, 2                      ; * 4
    sub r10d, eax                   ; adjusted exponent

    ; Convert to double: value = mantissa * 2^exponent
    ; Use integer -> double conversion then ldexp
    cvtsi2sd xmm0, rcx             ; mantissa as double

    ; Apply exponent via repeated multiply/divide by 2
    test r10d, r10d
    jz .ffh_apply_sign
    js .ffh_neg_exp_apply

    ; Positive exponent: multiply by 2^exp
.ffh_pos_exp:
    ; Use a loop to multiply by 2 for each bit
    mov ecx, r10d
.ffh_mul_loop:
    test ecx, ecx
    jz .ffh_apply_sign
    addsd xmm0, xmm0              ; xmm0 *= 2
    dec ecx
    jmp .ffh_mul_loop

.ffh_neg_exp_apply:
    neg r10d
    mov ecx, r10d
    mov rax, 0x3FF0000000000000    ; 1.0
    movq xmm1, rax
    mov rax, 0x4000000000000000    ; 2.0
    movq xmm2, rax
.ffh_div_loop:
    test ecx, ecx
    jz .ffh_apply_sign
    divsd xmm0, xmm2              ; xmm0 /= 2
    dec ecx
    jmp .ffh_div_loop

.ffh_apply_sign:
    test r13d, r13d
    jz .ffh_return
    ; Negate
    mov rax, 0x8000000000000000
    movq xmm1, rax
    xorpd xmm0, xmm1

.ffh_return:
    movq rax, xmm0
    mov edx, TAG_FLOAT
    pop r13
    pop r12
    pop rbx
    leave
    ret

; Local helper: convert hex char in al to value in eax, or -1
.ffh_hex_val:
    movzx eax, byte [r12 + rbx]
    cmp al, '0'
    jb .ffh_hv_bad
    cmp al, '9'
    ja .ffh_hv_alpha
    sub eax, '0'
    ret
.ffh_hv_alpha:
    or al, 0x20                     ; lowercase
    cmp al, 'a'
    jb .ffh_hv_bad
    cmp al, 'f'
    ja .ffh_hv_bad
    sub eax, 'a'
    add eax, 10
    ret
.ffh_hv_bad:
    mov eax, -1
    ret

.ffh_parse_error:
    lea rdi, [rel exc_ValueError_type]
    CSTRING rsi, "invalid hexadecimal floating-point string"
    call raise_exception
END_FUNC float_classmethod_fromhex


;; ############################################################################
;;                       METHODS_INIT
;; ############################################################################

;; ============================================================================
;; methods_init()
;; Populate tp_dict for str_type, list_type, dict_type
;; ============================================================================
DEF_FUNC methods_init
    push rbx
    push r12

    ;; --- str methods ---
    call dict_new
    mov rbx, rax            ; rbx = str method dict

    mov rdi, rbx
    lea rsi, [rel mn_upper]
    lea rdx, [rel str_method_upper]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_lower]
    lea rdx, [rel str_method_lower]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_strip]
    lea rdx, [rel str_method_strip]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_startswith]
    lea rdx, [rel str_method_startswith]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_endswith]
    lea rdx, [rel str_method_endswith]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_find]
    lea rdx, [rel str_method_find]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_replace]
    lea rdx, [rel str_method_replace]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_join]
    lea rdx, [rel str_method_join]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_split]
    lea rdx, [rel str_method_split]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_format]
    lea rdx, [rel str_method_format]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_lstrip]
    lea rdx, [rel str_method_lstrip]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_rstrip]
    lea rdx, [rel str_method_rstrip]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_count]
    lea rdx, [rel str_method_count]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_index]
    lea rdx, [rel str_method_index]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_rfind]
    lea rdx, [rel str_method_rfind]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_isdigit]
    lea rdx, [rel str_method_isdigit]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_isalpha]
    lea rdx, [rel str_method_isalpha]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_removeprefix]
    lea rdx, [rel str_method_removeprefix]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_removesuffix]
    lea rdx, [rel str_method_removesuffix]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_encode]
    lea rdx, [rel str_method_encode]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_isalnum]
    lea rdx, [rel str_method_isalnum]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_isspace]
    lea rdx, [rel str_method_isspace]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_isupper]
    lea rdx, [rel str_method_isupper]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_islower]
    lea rdx, [rel str_method_islower]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_title]
    lea rdx, [rel str_method_title]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_capitalize]
    lea rdx, [rel str_method_capitalize]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_swapcase]
    lea rdx, [rel str_method_swapcase]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_casefold]
    lea rdx, [rel str_method_casefold]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_center]
    lea rdx, [rel str_method_center]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_ljust]
    lea rdx, [rel str_method_ljust]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_rjust]
    lea rdx, [rel str_method_rjust]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_zfill]
    lea rdx, [rel str_method_zfill]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_rindex]
    lea rdx, [rel str_method_rindex]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_istitle]
    lea rdx, [rel str_method_istitle]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_partition]
    lea rdx, [rel str_method_partition]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_rpartition]
    lea rdx, [rel str_method_rpartition]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_rsplit]
    lea rdx, [rel str_method_rsplit]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_splitlines]
    lea rdx, [rel str_method_splitlines]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_expandtabs]
    lea rdx, [rel str_method_expandtabs]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_translate]
    lea rdx, [rel str_method_translate]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_format_map]
    lea rdx, [rel str_method_format_map]
    call add_method_to_dict

    ; Add maketrans as staticmethod
    lea rdi, [rel str_staticmethod_maketrans]
    lea rsi, [rel mn_maketrans]
    call builtin_func_new
    push rax

    mov edi, PyStaticMethodObject_size
    lea rsi, [rel staticmethod_type]
    call gc_alloc
    pop rcx
    mov [rax + PyStaticMethodObject.sm_callable], rcx
    push rax
    mov rdi, rax
    call gc_track
    pop rax
    push rax

    lea rdi, [rel mn_maketrans]
    call str_from_cstr_heap
    push rax

    mov rdi, rbx
    mov rsi, rax
    mov rdx, [rsp + 8]
    mov ecx, TAG_PTR
    mov r8d, TAG_PTR
    call dict_set

    pop rdi
    call obj_decref
    pop rdi
    call obj_decref

    ; Store dict in str_type.tp_dict
    lea rax, [rel str_type]
    mov [rax + PyTypeObject.tp_dict], rbx
    ; INCREF the dict (type holds ref; dict_new gave us refcnt=1, which we keep)

    ;; --- list methods ---
    call dict_new
    mov rbx, rax

    mov rdi, rbx
    lea rsi, [rel mn_append]
    lea rdx, [rel list_method_append]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_pop]
    lea rdx, [rel list_method_pop]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_insert]
    lea rdx, [rel list_method_insert]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_reverse]
    lea rdx, [rel list_method_reverse]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_sort]
    lea rdx, [rel list_method_sort]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_index]
    lea rdx, [rel list_method_index]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_count]
    lea rdx, [rel list_method_count]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_copy]
    lea rdx, [rel list_method_copy]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_clear]
    lea rdx, [rel list_method_clear]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_extend]
    lea rdx, [rel list_method_extend]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_remove]
    lea rdx, [rel list_method_remove]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn___reversed__]
    lea rdx, [rel list_method_reversed]
    call add_method_to_dict

    ; Store in list_type.tp_dict
    lea rax, [rel list_type]
    mov [rax + PyTypeObject.tp_dict], rbx

    ;; --- dict methods ---
    call dict_new
    mov rbx, rax

    mov rdi, rbx
    lea rsi, [rel mn_get]
    lea rdx, [rel dict_method_get]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_keys]
    lea rdx, [rel dict_method_keys]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_values]
    lea rdx, [rel dict_method_values]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_items]
    lea rdx, [rel dict_method_items]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_pop]
    lea rdx, [rel dict_method_pop_v2]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_clear]
    lea rdx, [rel dict_method_clear]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_update]
    lea rdx, [rel dict_method_update]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_setdefault]
    lea rdx, [rel dict_method_setdefault]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_copy]
    lea rdx, [rel dict_method_copy]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_popitem]
    lea rdx, [rel dict_method_popitem]
    call add_method_to_dict

    extern dict_reversed
    mov rdi, rbx
    lea rsi, [rel mn___reversed__]
    lea rdx, [rel dict_reversed]
    call add_method_to_dict

    ; Add fromkeys as classmethod
    lea rdi, [rel dict_classmethod_fromkeys]
    lea rsi, [rel mn_fromkeys]
    call builtin_func_new
    push rax

    mov edi, PyClassMethodObject_size
    lea rsi, [rel classmethod_type]
    call gc_alloc
    pop rcx
    mov [rax + PyClassMethodObject.cm_callable], rcx
    push rax
    mov rdi, rax
    call gc_track
    pop rax
    push rax

    lea rdi, [rel mn_fromkeys]
    call str_from_cstr_heap
    push rax

    mov rdi, rbx
    mov rsi, rax
    mov rdx, [rsp + 8]
    mov ecx, TAG_PTR
    mov r8d, TAG_PTR
    call dict_set

    pop rdi
    call obj_decref
    pop rdi
    call obj_decref

    ; Store in dict_type.tp_dict
    lea rax, [rel dict_type]
    mov [rax + PyTypeObject.tp_dict], rbx

    ;; --- tuple methods ---
    call dict_new
    mov rbx, rax

    mov rdi, rbx
    lea rsi, [rel mn_index]
    lea rdx, [rel tuple_method_index]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_count]
    lea rdx, [rel tuple_method_count]
    call add_method_to_dict

    ; Store in tuple_type.tp_dict
    lea rax, [rel tuple_type]
    mov [rax + PyTypeObject.tp_dict], rbx

    ;; --- set methods ---
    call dict_new
    mov rbx, rax

    mov rdi, rbx
    lea rsi, [rel mn_add]
    lea rdx, [rel set_method_add]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_remove]
    lea rdx, [rel set_method_remove]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_discard]
    lea rdx, [rel set_method_discard]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_pop]
    lea rdx, [rel set_method_pop]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_clear]
    lea rdx, [rel set_method_clear]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_copy]
    lea rdx, [rel set_method_copy]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_union]
    lea rdx, [rel set_method_union]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_intersection]
    lea rdx, [rel set_method_intersection]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_difference]
    lea rdx, [rel set_method_difference]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_symmetric_difference]
    lea rdx, [rel set_method_symmetric_difference]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_issubset]
    lea rdx, [rel set_method_issubset]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_issuperset]
    lea rdx, [rel set_method_issuperset]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_isdisjoint]
    lea rdx, [rel set_method_isdisjoint]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_update]
    lea rdx, [rel set_method_update]
    call add_method_to_dict

    ; Store in set_type.tp_dict
    lea rax, [rel set_type]
    mov [rax + PyTypeObject.tp_dict], rbx

    ;; --- object_type methods (just __new__) ---
    call dict_new
    mov rbx, rax

    ; Create builtin_func for object_new_fn
    lea rdi, [rel object_new_fn]
    lea rsi, [rel mn___new__]
    call builtin_func_new
    push rax                    ; save builtin_func

    ; Wrap in PyStaticMethodObject (GC-tracked)
    mov edi, PyStaticMethodObject_size
    lea rsi, [rel staticmethod_type]
    call gc_alloc
    pop rcx                     ; builtin_func
    mov [rax + PyStaticMethodObject.sm_callable], rcx
    push rax                    ; save staticmethod wrapper
    mov rdi, rax
    call gc_track
    pop rax
    push rax                    ; re-save

    ; Create key string
    lea rdi, [rel mn___new__]
    call str_from_cstr_heap
    push rax                    ; save key

    ; dict_set(dict, key, staticmethod_wrapper, TAG_PTR, TAG_PTR)
    mov rdi, rbx
    mov rsi, rax                ; key
    mov rdx, [rsp + 8]         ; staticmethod wrapper
    mov ecx, TAG_PTR
    mov r8d, TAG_PTR
    call dict_set

    ; DECREF key
    pop rdi
    call obj_decref

    ; DECREF staticmethod wrapper (dict_set did INCREF)
    pop rdi
    call obj_decref

    ; Store in object_type.tp_dict
    lea rax, [rel object_type]
    mov [rax + PyTypeObject.tp_dict], rbx

    ;; --- int_type methods ---
    call dict_new
    mov rbx, rax

    mov rdi, rbx
    lea rsi, [rel mn_bit_length]
    lea rdx, [rel int_method_bit_length]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_bit_count]
    lea rdx, [rel int_method_bit_count]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_conjugate]
    lea rdx, [rel int_method_conjugate]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_to_bytes]
    lea rdx, [rel int_method_to_bytes]
    call add_method_to_dict

    ; Add from_bytes as classmethod
    lea rdi, [rel int_classmethod_from_bytes]
    lea rsi, [rel mn_from_bytes]
    call builtin_func_new
    push rax                    ; save builtin_func

    ; Wrap in PyClassMethodObject (GC-tracked)
    mov edi, PyClassMethodObject_size
    lea rsi, [rel classmethod_type]
    call gc_alloc
    pop rcx                     ; builtin_func
    mov [rax + PyClassMethodObject.cm_callable], rcx
    push rax                    ; save classmethod wrapper
    mov rdi, rax
    call gc_track
    pop rax
    push rax                    ; re-save

    ; Create key string
    lea rdi, [rel mn_from_bytes]
    call str_from_cstr_heap
    push rax                    ; save key

    ; dict_set(dict, key, classmethod_wrapper, TAG_PTR, TAG_PTR)
    mov rdi, rbx
    mov rsi, rax                ; key
    mov rdx, [rsp + 8]         ; classmethod wrapper
    mov ecx, TAG_PTR
    mov r8d, TAG_PTR
    call dict_set

    ; DECREF key
    pop rdi
    call obj_decref
    ; DECREF classmethod wrapper (dict_set did INCREF)
    pop rdi
    call obj_decref

    ; Store in int_type.tp_dict
    lea rax, [rel int_type]
    mov [rax + PyTypeObject.tp_dict], rbx

    ;; --- float_type methods ---
    call dict_new
    mov rbx, rax

    mov rdi, rbx
    lea rsi, [rel mn_is_integer]
    lea rdx, [rel float_method_is_integer]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_conjugate]
    lea rdx, [rel float_method_conjugate]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_as_integer_ratio]
    lea rdx, [rel float_method_as_integer_ratio]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_hex]
    lea rdx, [rel float_method_hex]
    call add_method_to_dict

    ; Add fromhex as classmethod
    lea rdi, [rel float_classmethod_fromhex]
    lea rsi, [rel mn_fromhex]
    call builtin_func_new
    push rax

    mov edi, PyClassMethodObject_size
    lea rsi, [rel classmethod_type]
    call gc_alloc
    pop rcx
    mov [rax + PyClassMethodObject.cm_callable], rcx
    push rax
    mov rdi, rax
    call gc_track
    pop rax
    push rax

    lea rdi, [rel mn_fromhex]
    call str_from_cstr_heap
    push rax

    mov rdi, rbx
    mov rsi, rax
    mov rdx, [rsp + 8]
    mov ecx, TAG_PTR
    mov r8d, TAG_PTR
    call dict_set

    pop rdi
    call obj_decref
    pop rdi
    call obj_decref

    ; Store in float_type.tp_dict
    lea rax, [rel float_type]
    mov [rax + PyTypeObject.tp_dict], rbx

    ;; --- bytes_type methods (extend tp_dict, keep tp_getattr for .decode()) ---
    call dict_new
    mov rbx, rax

    mov rdi, rbx
    lea rsi, [rel mn_hex]
    lea rdx, [rel bytes_method_hex]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_startswith]
    lea rdx, [rel bytes_method_startswith]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_endswith]
    lea rdx, [rel bytes_method_endswith]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_count]
    lea rdx, [rel bytes_method_count]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_find]
    lea rdx, [rel bytes_method_find]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_replace]
    lea rdx, [rel bytes_method_replace]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_split]
    lea rdx, [rel bytes_method_split]
    call add_method_to_dict

    mov rdi, rbx
    lea rsi, [rel mn_join]
    lea rdx, [rel bytes_method_join]
    call add_method_to_dict

    ; Store in bytes_type.tp_dict
    lea rax, [rel bytes_type]
    mov [rax + PyTypeObject.tp_dict], rbx

    pop r12
    pop rbx
    leave
    ret
END_FUNC methods_init

;; ============================================================================
;; Data section
;; ============================================================================
section .rodata

empty_str_cstr: db 0

; Method name strings
mn_upper:       db "upper", 0
mn_lower:       db "lower", 0
mn_strip:       db "strip", 0
mn_startswith:  db "startswith", 0
mn_endswith:    db "endswith", 0
mn_find:        db "find", 0
mn_replace:     db "replace", 0
mn_join:        db "join", 0
mn_split:       db "split", 0
mn_format:      db "format", 0
mn_append:      db "append", 0
mn_pop:         db "pop", 0
mn_insert:      db "insert", 0
mn_reverse:     db "reverse", 0
mn_sort:        db "sort", 0
mn_index:       db "index", 0
mn_count:       db "count", 0
mn_copy:        db "copy", 0
mn_clear:       db "clear", 0
mn_extend:      db "extend", 0
mn_get:         db "get", 0
mn_keys:        db "keys", 0
mn_values:      db "values", 0
mn_items:       db "items", 0
mn_update:      db "update", 0
mn_lstrip:      db "lstrip", 0
mn_rstrip:      db "rstrip", 0
mn_rfind:       db "rfind", 0
mn_isdigit:     db "isdigit", 0
mn_isalpha:     db "isalpha", 0
mn_removeprefix: db "removeprefix", 0
mn_removesuffix: db "removesuffix", 0
mn_encode:      db "encode", 0
mn_setdefault:  db "setdefault", 0
mn_popitem:     db "popitem", 0
mn_remove:      db "remove", 0
mn_add:         db "add", 0
mn_discard:     db "discard", 0
mn_union:       db "union", 0
mn_intersection: db "intersection", 0
mn_difference:  db "difference", 0
mn_symmetric_difference: db "symmetric_difference", 0
mn_issubset:    db "issubset", 0
mn_issuperset:  db "issuperset", 0
mn_isdisjoint:  db "isdisjoint", 0
mn_isalnum:     db "isalnum", 0
mn_isspace:     db "isspace", 0
mn_isupper:     db "isupper", 0
mn_islower:     db "islower", 0
mn___new__:     db "__new__", 0
mn_title:       db "title", 0
mn_capitalize:  db "capitalize", 0
mn_swapcase:    db "swapcase", 0
mn_casefold:    db "casefold", 0
mn_center:      db "center", 0
mn_ljust:       db "ljust", 0
mn_rjust:       db "rjust", 0
mn_zfill:       db "zfill", 0
mn_rindex:      db "rindex", 0
mn_istitle:     db "istitle", 0
mn_partition:   db "partition", 0
mn_rpartition:  db "rpartition", 0
mn_rsplit:      db "rsplit", 0
mn_splitlines:  db "splitlines", 0
mn_expandtabs:  db "expandtabs", 0
mn_translate:   db "translate", 0
mn_format_map:  db "format_map", 0
mn_maketrans:   db "maketrans", 0
; int method names
mn_to_bytes:    db "to_bytes", 0
mn_from_bytes:  db "from_bytes", 0
mn_bit_length:  db "bit_length", 0
mn_bit_count:   db "bit_count", 0
mn___index__:   db "__index__", 0
mn_conjugate:   db "conjugate", 0
mn___abs__:     db "__abs__", 0
mn___int__:     db "__int__", 0
mn___float__:   db "__float__", 0
; float method names
mn_is_integer:  db "is_integer", 0
mn_as_integer_ratio: db "as_integer_ratio", 0
mn___trunc__:   db "__trunc__", 0
; float method names (continued)
mn_fromhex:     db "fromhex", 0
; bytes method names
mn_hex:         db "hex", 0
mn_decode:      db "decode", 0
; dict method names (continued)
mn_fromkeys:    db "fromkeys", 0
mn___reversed__: db "__reversed__", 0
