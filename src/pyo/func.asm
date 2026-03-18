; func_obj.asm - Function object type for apython
; Implements PyFuncObject: creation, calling, deallocation, and type descriptor

%include "macros.inc"
%include "object.inc"
%include "types.inc"
%include "frame.inc"

extern ap_malloc
extern gc_alloc
extern gc_track
extern gc_dealloc
extern ap_free
extern obj_decref
extern obj_incref
extern obj_dealloc
extern str_from_cstr
extern eval_frame
extern frame_new
extern frame_free
extern tuple_new
extern type_type
extern func_traverse
extern func_clear
extern exc_TypeError_type
extern raise_exception

; CO_FLAGS
CO_VARARGS equ 0x04
CO_VARKEYWORDS equ 0x08

; ---------------------------------------------------------------------------
; func_new(PyCodeObject *code, PyObject *globals) -> PyFuncObject*
; Allocate and initialize a new function object.
; rdi = code object, rsi = globals dict
; ---------------------------------------------------------------------------
DEF_FUNC func_new
    push rbx
    push r12
    push r13
    push r14                ; padding for 16-byte stack alignment

    mov rbx, rdi            ; rbx = code
    mov r12, rsi            ; r12 = globals

    ; Allocate PyFuncObject (GC-tracked)
    mov edi, PyFuncObject_size
    lea rsi, [rel func_type]
    call gc_alloc
    mov r13, rax            ; r13 = new func object (ob_refcnt=1, ob_type set)

    ; func_code = code; INCREF code
    mov [r13 + PyFuncObject.func_code], rbx
    INCREF rbx

    ; func_globals = globals; INCREF globals
    mov [r13 + PyFuncObject.func_globals], r12
    INCREF r12

    ; func_name = code->co_name; INCREF name
    mov rax, [rbx + PyCodeObject.co_name]
    mov [r13 + PyFuncObject.func_name], rax
    INCREF rax

    ; func_defaults = NULL
    mov qword [r13 + PyFuncObject.func_defaults], 0

    ; func_closure = NULL
    mov qword [r13 + PyFuncObject.func_closure], 0

    ; func_kwdefaults = NULL
    mov qword [r13 + PyFuncObject.func_kwdefaults], 0

    ; func_dict = NULL
    mov qword [r13 + PyFuncObject.func_dict], 0

    mov rdi, r13
    call gc_track

    mov rax, r13            ; return func object
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC func_new

; ---------------------------------------------------------------------------
; func_call(PyFuncObject *callable, PyObject **args_ptr, int nargs) -> PyObject*
; tp_call implementation for function objects.
; rdi = function object, rsi = pointer to args array, edx = nargs
;
; r12 still holds the CALLER's frame pointer (callee-saved, set by eval loop,
; preserved through op_call).
;
; Full argument binding following CPython initialize_locals:
;   1. Create **kwargs dict if CO_VARKEYWORDS
;   2. Copy positional args
;   3. Handle *args (CO_VARARGS)
;   4. Match keyword args (from kw_names_pending)
;   5. Apply positional defaults (func_defaults)
;   6. Apply kw-only defaults (func_kwdefaults)
; ---------------------------------------------------------------------------
extern kw_names_pending
extern dict_new
extern dict_set
extern dict_get
extern ap_strcmp

DEF_FUNC func_call
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 56             ; 48 bytes locals + 8 alignment
    ; Locals layout:
    ;   [rsp+0]  = kw_names_pending tuple (or NULL)
    ;   [rsp+8]  = positional_count
    ;   [rsp+16] = return value from eval_frame
    ;   [rsp+24] = kwargs_dict ptr (or NULL)
    ;   [rsp+32] = (scratch)
    ;   [rsp+40] = (scratch)

    mov rbx, rdi            ; rbx = function object
    mov r14, rsi            ; r14 = args_ptr
    mov r15d, edx           ; r15d = nargs

    ; Read and clear kw_names_pending
    mov rax, [rel kw_names_pending]
    mov [rsp+0], rax
    mov qword [rel kw_names_pending], 0

    ; Compute positional_count = nargs - len(kw_names) or nargs if no kw
    mov ecx, r15d
    test rax, rax
    jz .no_kw_adjust
    mov rdx, [rax + PyTupleObject.ob_size]
    sub ecx, edx
.no_kw_adjust:
    mov [rsp+8], ecx        ; save positional_count
    mov qword [rsp+24], 0   ; kwargs_dict = NULL

    ; Check too many positional args (unless CO_VARARGS)
    mov rdi, [rbx + PyFuncObject.func_code]
    mov eax, [rdi + PyCodeObject.co_argcount]
    cmp ecx, eax
    jbe .args_count_ok
    mov edx, [rdi + PyCodeObject.co_flags]
    test edx, CO_VARARGS
    jnz .args_count_ok
    ; Too many positional args — raise TypeError with CPython-format message
    ; ecx = given positional count, rdi = code object, rbx = func
    mov esi, ecx               ; esi = nargs_given
    mov rdi, rbx               ; rdi = func
    call raise_too_many_positional
    ; (does not return)
.args_count_ok:

    ; Get builtins from global (avoids r12 caller-frame assumption)
    extern builtins_dict_global
    mov rdx, [rel builtins_dict_global]

    ; Create new frame: frame_new(code, globals, builtins, locals=NULL)
    mov rdi, [rbx + PyFuncObject.func_code]
    mov rsi, [rbx + PyFuncObject.func_globals]
    xor ecx, ecx
    call frame_new
    mov r12, rax            ; r12 = new frame

    ; Store function object in frame for COPY_FREE_VARS
    mov [r12 + PyFrame.func_obj], rbx

    ; === Phase 1: Create **kwargs dict if CO_VARKEYWORDS ===
    mov rdi, [rbx + PyFuncObject.func_code]
    mov ecx, [rdi + PyCodeObject.co_flags]
    test ecx, CO_VARKEYWORDS
    jz .no_kwargs_dict

    call dict_new
    mov [rsp+24], rax       ; save kwargs_dict

    ; Place kwargs dict at localsplus[co_argcount + co_kwonlyargcount + varargs_offset]
    mov rdi, [rbx + PyFuncObject.func_code]
    mov ecx, [rdi + PyCodeObject.co_argcount]
    add ecx, [rdi + PyCodeObject.co_kwonlyargcount]
    mov edx, [rdi + PyCodeObject.co_flags]
    test edx, CO_VARARGS
    jz .no_varargs_offset
    inc ecx
.no_varargs_offset:
    movsxd rcx, ecx
    mov rdx, rcx
    shl rcx, 3                 ; localsplus 8 bytes/slot
    mov [r12 + PyFrame.localsplus + rcx], rax
    mov rsi, [r12 + PyFrame.locals_tag_base]
    mov byte [rsi + rdx], TAG_PTR  ; dict is always heap ptr

.no_kwargs_dict:
    ; === Phase 2: Copy positional args ===
    mov rdi, [rbx + PyFuncObject.func_code]
    mov eax, [rdi + PyCodeObject.co_argcount]
    mov ecx, [rsp+8]       ; positional_count
    cmp ecx, eax
    cmovb eax, ecx         ; min(positional_count, co_argcount)
    xor ecx, ecx
    test eax, eax
    jz .positional_done
    mov r10d, eax                  ; r10d = loop limit (preserved across loop)

.bind_positional:
    mov r8, rcx
    mov r11, rcx
    shl r8, 3                      ; localsplus at 8-byte stride
    mov rax, rcx
    shl rax, 4                     ; args at 16-byte stride
    mov rdx, [r14 + rax]           ; arg payload
    mov r9, [r14 + rax + 8]        ; arg tag
    mov [r12 + PyFrame.localsplus + r8], rdx
    mov rsi, [r12 + PyFrame.locals_tag_base]
    mov byte [rsi + r11], r9b
    INCREF_VAL rdx, r9
    inc ecx
    cmp ecx, r10d
    jb .bind_positional

.positional_done:
    ; === Phase 3: Handle *args (CO_VARARGS) ===
    mov rdi, [rbx + PyFuncObject.func_code]
    mov eax, [rdi + PyCodeObject.co_argcount]
    mov ecx, [rdi + PyCodeObject.co_flags]
    test ecx, CO_VARARGS
    jz .varargs_done

    ; *args slot = co_argcount + co_kwonlyargcount
    ; (localsplus layout: [positional] [kw-only] [*args] [**kwargs])
    mov ecx, [rdi + PyCodeObject.co_kwonlyargcount]
    add eax, ecx             ; eax = slot index for *args

    ; excess = positional_count - co_argcount
    mov rdi, [rbx + PyFuncObject.func_code]
    mov ecx, [rsp+8]         ; positional_count
    sub ecx, [rdi + PyCodeObject.co_argcount]
    jle .empty_varargs

    push rax
    movsx rdi, ecx
    push rdi
    call tuple_new
    pop rcx                   ; rcx = excess count
    pop rdx                   ; rdx = *args slot index

    ; Fill tuple: copy excess positional args
    mov rdi, [rbx + PyFuncObject.func_code]
    mov r8d, [rdi + PyCodeObject.co_argcount] ; source start index
    xor esi, esi
.fill_varargs:
    cmp esi, ecx
    jge .store_varargs
    lea edi, [r8d + esi]
    movsxd rdi, edi
    mov r10, rdi
    shl r10, 4                      ; source index * 16 (args stride)
    mov r9, [r14 + r10]             ; value payload from args
    mov r11, [r14 + r10 + 8]        ; value tag from args
    mov r10, [rax + PyTupleObject.ob_item]       ; payloads
    mov rdi, [rax + PyTupleObject.ob_item_tags]  ; tags
    mov [r10 + rsi*8], r9           ; payload
    mov byte [rdi + rsi], r11b      ; tag
    INCREF_VAL r9, r11
    inc esi
    jmp .fill_varargs

.store_varargs:
    mov rsi, [r12 + PyFrame.locals_tag_base]
    mov r11, rdx
    shl rdx, 3                 ; localsplus 8 bytes/slot
    mov [r12 + PyFrame.localsplus + rdx], rax
    mov byte [rsi + r11], TAG_PTR
    jmp .varargs_done

.empty_varargs:
    push rax                    ; save slot index
    xor edi, edi
    call tuple_new
    pop rdx                     ; rdx = slot index
    mov rsi, [r12 + PyFrame.locals_tag_base]
    mov r11, rdx
    shl rdx, 3                 ; localsplus 8 bytes/slot
    mov [r12 + PyFrame.localsplus + rdx], rax
    mov byte [rsi + r11], TAG_PTR

.varargs_done:
    ; === Phase 4: Match keyword args ===
    mov rax, [rsp+0]       ; kw_names_pending
    test rax, rax
    jz .kw_done

    ; Call helper: func_bind_kwargs(func, frame, args, positional_count, kw_names, kwargs_dict)
    mov rdi, rbx            ; function object
    mov rsi, r12            ; frame
    mov rdx, r14            ; args_ptr
    mov ecx, [rsp+8]        ; positional_count
    mov r8, rax              ; kw_names tuple
    mov r9, [rsp+24]         ; kwargs_dict (NULL if no CO_VARKEYWORDS)
    call func_bind_kwargs

.kw_done:
    ; === Phase 5: Apply positional defaults ===
    mov rax, [rbx + PyFuncObject.func_defaults]
    test rax, rax
    jz .pos_defaults_done

    mov rdi, [rbx + PyFuncObject.func_code]
    mov edx, [rdi + PyCodeObject.co_argcount]

    ; If all positional slots already filled, skip
    mov ecx, [rsp+8]       ; positional_count
    cmp ecx, edx
    jge .pos_defaults_done

    ; defcount = len(defaults)
    mov rcx, [rax + PyTupleObject.ob_size]
    ; m = co_argcount - defcount
    mov esi, edx
    sub rsi, rcx

    ; Fill localsplus[i] for unfilled slots with defaults
    xor edi, edi            ; i = 0 (check all positional slots)
.defaults_loop:
    cmp edi, edx
    jge .pos_defaults_done

    mov r10, rdi
    mov r11, [r12 + PyFrame.locals_tag_base]
    cmp byte [r11 + r10], 0
    jne .defaults_next

    ; Must have a default (i >= m)
    movsxd r8, edi
    cmp r8, rsi
    jl .defaults_next

    ; defaults[i - m]
    mov r8, rdi
    sub r8, rsi
    mov r9, [rax + PyTupleObject.ob_item]       ; payloads
    mov r10, [rax + PyTupleObject.ob_item_tags] ; tags
    mov r9, [r9 + r8*8]                          ; payload
    movzx r10d, byte [r10 + r8]                  ; tag
    movsxd r8, edi
    mov r11, r8
    shl r8, 3                  ; localsplus 8 bytes/slot
    mov [r12 + PyFrame.localsplus + r8], r9
    mov r8, [r12 + PyFrame.locals_tag_base]
    mov byte [r8 + r11], r10b
    INCREF_VAL r9, r10

.defaults_next:
    inc edi
    jmp .defaults_loop

.pos_defaults_done:
    ; === Phase 6: Apply kw-only defaults ===
    mov rax, [rbx + PyFuncObject.func_kwdefaults]
    test rax, rax
    jz .kw_defaults_done

    mov rdi, [rbx + PyFuncObject.func_code]
    mov ecx, [rdi + PyCodeObject.co_argcount]       ; ecx = co_argcount
    mov edx, [rdi + PyCodeObject.co_kwonlyargcount] ; edx = co_kwonlyargcount
    test edx, edx
    jz .kw_defaults_done

    ; For i in [co_argcount..co_argcount+co_kwonlyargcount):
    ;   if localsplus[i] is NULL: look up name in kwdefaults dict
    mov esi, ecx            ; esi = i = co_argcount
    add edx, ecx            ; edx = co_argcount + co_kwonlyargcount (end)

.kw_defaults_loop:
    cmp esi, edx
    jge .kw_defaults_done

    movsxd r8, esi
    mov r11, [r12 + PyFrame.locals_tag_base]
    cmp byte [r11 + r8], 0
    jne .kw_defaults_next

    ; Slot is NULL - look up param name in kwdefaults dict
    ; rax = kwdefaults dict, esi = param index
    ; Get param name from co_localsplusnames[i]
    push rax
    push rdx
    push rsi

    mov rdi, [rbx + PyFuncObject.func_code]
    mov rdi, [rdi + PyCodeObject.co_localsplusnames]
    mov r8, [rdi + PyTupleObject.ob_item]            ; payloads
    movsxd r9, esi
    mov rsi, [r8 + r9*8]                              ; param name string

    ; dict_get(kwdefaults, param_name) -> borrowed ref or NULL
    mov rdi, rax            ; kwdefaults dict
    mov edx, TAG_PTR
    call dict_get

    mov r8, rax             ; r8 = value payload (or NULL)
    mov r10, rdx            ; r10 = value tag from dict_get
    pop rsi
    pop rdx
    pop rax                 ; rax = kwdefaults dict

    test r10, r10
    jz .kw_defaults_next    ; not in kwdefaults, skip (would be error)

    ; Assign and INCREF
    movsxd r9, esi
    mov r11, r9
    shl r9, 3                  ; localsplus 8 bytes/slot
    mov [r12 + PyFrame.localsplus + r9], r8
    mov rsi, [r12 + PyFrame.locals_tag_base]
    mov byte [rsi + r11], r10b  ; tag from dict_get
    INCREF_VAL r8, r10

.kw_defaults_next:
    inc esi
    jmp .kw_defaults_loop

.kw_defaults_done:
    ; === Phase 6.5: Validate all required args are filled ===
    mov rdi, [rbx + PyFuncObject.func_code]
    mov ecx, [rdi + PyCodeObject.co_argcount]
    add ecx, [rdi + PyCodeObject.co_kwonlyargcount]
    test ecx, ecx
    jz .args_valid
    xor esi, esi
.check_args_loop:
    cmp esi, ecx
    jge .args_valid
    movsxd r8, esi
    mov r9, [r12 + PyFrame.locals_tag_base]
    cmp byte [r9 + r8], 0
    je .args_missing
    inc esi
    jmp .check_args_loop
.args_missing:
    ; Free the frame before raising
    push rsi
    mov rdi, r12
    call frame_free
    pop rsi
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "function missing required argument"
    call raise_exception
.args_valid:
    ; === Phase 7: Call eval_frame ===
    mov rdi, r12
    call eval_frame
    mov [rsp+16], rax       ; save return value payload
    mov [rsp+24], rdx       ; save return value tag

    ; Free the frame (unless generator owns it: instr_ptr != 0)
    cmp qword [r12 + PyFrame.instr_ptr], 0
    jne .skip_frame_free
    mov rdi, r12
    call frame_free
.skip_frame_free:

    mov rax, [rsp+16]       ; return value payload
    mov rdx, [rsp+24]       ; return value tag

    add rsp, 56
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC func_call

; ---------------------------------------------------------------------------
; func_bind_kwargs - Bind keyword arguments to frame locals
;
; rdi = function object
; rsi = frame
; rdx = args_ptr
; ecx = positional_count
; r8  = kw_names tuple (NOT NULL)
; r9  = kwargs_dict (or NULL if no CO_VARKEYWORDS)
; ---------------------------------------------------------------------------
DEF_FUNC func_bind_kwargs
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40             ; 32 bytes locals + 8 alignment
    ; Locals:
    ;   [rsp+0]  = kwargs_dict (or NULL)
    ;   [rsp+8]  = kw_count
    ;   [rsp+16] = kw_index
    ;   [rsp+24] = value_index (index into args for current kw value)

    mov rbx, rdi            ; function object
    mov r12, rsi            ; frame
    mov r13, rdx            ; args_ptr
    mov r14, r8             ; kw_names tuple
    mov r15d, ecx           ; positional_count

    mov [rsp+0], r9         ; kwargs_dict

    mov rax, [r14 + PyTupleObject.ob_size]
    mov [rsp+8], rax        ; kw_count

    mov qword [rsp+16], 0   ; kw_index = 0

.kw_outer:
    mov rcx, [rsp+16]
    cmp rcx, [rsp+8]
    jge .kw_outer_done

    ; kw_name = kw_names[kw_index]
    mov rsi, [r14 + PyTupleObject.ob_item]       ; payloads
    mov rsi, [rsi + rcx*8]

    ; value_index = positional_count + kw_index
    lea eax, [r15d + ecx]
    movsxd rax, eax
    mov [rsp+24], rax

    ; Search co_localsplusnames[co_posonlyargcount..co_argcount+co_kwonlyargcount]
    mov rdi, [rbx + PyFuncObject.func_code]
    mov r8, [rdi + PyCodeObject.co_localsplusnames]
    mov r9d, [rdi + PyCodeObject.co_posonlyargcount]
    mov r10d, [rdi + PyCodeObject.co_argcount]
    add r10d, [rdi + PyCodeObject.co_kwonlyargcount]

    mov ecx, r9d            ; j = co_posonlyargcount

.kw_inner:
    cmp ecx, r10d
    jge .kw_not_found

    movsxd rdx, ecx
    mov r11, [r8 + PyTupleObject.ob_item]        ; payloads
    mov rax, [r11 + rdx*8]

    ; Fast path: pointer equality (interned strings)
    cmp rax, rsi
    je .kw_found

    ; Slow path: compare string content
    ; Check lengths first
    mov rdi, [rax + PyStrObject.ob_size]
    cmp rdi, [rsi + PyStrObject.ob_size]
    jne .kw_inner_next

    ; Compare string data (both null-terminated)
    push rcx
    push rsi
    push r8
    push r10
    lea rdi, [rax + PyStrObject.data]
    lea rsi, [rsi + PyStrObject.data]
    call ap_strcmp
    pop r10
    pop r8
    pop rsi
    pop rcx

    test eax, eax
    jz .kw_found

.kw_inner_next:
    inc ecx
    jmp .kw_inner

.kw_found:
    ; ecx = j (param index in localsplus)
    movsxd rdx, ecx
    mov r11, [r12 + PyFrame.locals_tag_base]
    ; Check if slot already filled (would be "multiple values" error)
    cmp byte [r11 + rdx], 0
    jne .kw_next            ; skip silently (TODO: error)

    ; Assign: localsplus[j] = args[value_index], INCREF
    mov rax, [rsp+24]
    shl rax, 4                ; args at 16-byte stride
    mov rdi, [r13 + rax]      ; arg payload
    mov rsi, [r13 + rax + 8]  ; arg tag
    mov [r12 + PyFrame.localsplus + rdx*8], rdi
    mov byte [r11 + rdx], sil
    INCREF_VAL rdi, rsi
    jmp .kw_next

.kw_not_found:
    ; Add to **kwargs if available
    mov rdi, [rsp+0]
    test rdi, rdi
    jz .kw_unexpected       ; no **kwargs, raise TypeError

    ; dict_set(kwargs_dict, key, value, value_tag)
    mov rax, [rsp+16]
    mov rsi, [r14 + PyTupleObject.ob_item]           ; payloads
    mov rsi, [rsi + rax*8]                           ; key = kw_name
    mov rax, [rsp+24]
    shl rax, 4                     ; * 16 (16-byte args stride)
    mov rcx, [r13 + rax + 8]      ; value tag
    mov rdx, [r13 + rax]          ; value payload
    mov r8d, TAG_PTR
    call dict_set
    jmp .kw_next

.kw_unexpected:
    ; Raise TypeError for unexpected keyword argument
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "got an unexpected keyword argument"
    call raise_exception

.kw_next:
    inc qword [rsp+16]
    jmp .kw_outer

.kw_outer_done:
    add rsp, 40
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC func_bind_kwargs

; ---------------------------------------------------------------------------
; func_dealloc(PyFuncObject *self)
; Releases references to internal objects and frees the function.
; rdi = function object
; ---------------------------------------------------------------------------
DEF_FUNC func_dealloc
    push rbx
    push r12                ; alignment padding (3 pushes = RSP aligned)

    mov rbx, rdi            ; rbx = func object

    ; DECREF func_code
    mov rdi, [rbx + PyFuncObject.func_code]
    call obj_decref

    ; DECREF func_globals
    mov rdi, [rbx + PyFuncObject.func_globals]
    call obj_decref

    ; DECREF func_name
    mov rdi, [rbx + PyFuncObject.func_name]
    call obj_decref

    ; XDECREF func_defaults (may be NULL)
    mov rdi, [rbx + PyFuncObject.func_defaults]
    test rdi, rdi
    jz .no_defaults
    call obj_decref
.no_defaults:

    ; XDECREF func_closure (may be NULL)
    mov rdi, [rbx + PyFuncObject.func_closure]
    test rdi, rdi
    jz .no_closure
    call obj_decref
.no_closure:

    ; XDECREF func_kwdefaults (may be NULL)
    mov rdi, [rbx + PyFuncObject.func_kwdefaults]
    test rdi, rdi
    jz .no_kwdefaults
    call obj_decref
.no_kwdefaults:

    ; XDECREF func_dict (may be NULL)
    mov rdi, [rbx + PyFuncObject.func_dict]
    test rdi, rdi
    jz .no_func_dict
    call obj_decref
.no_func_dict:

    ; Free the function object itself (GC-aware)
    mov rdi, rbx
    call gc_dealloc

    pop r12
    pop rbx
    leave
    ret
END_FUNC func_dealloc

; ---------------------------------------------------------------------------
; func_setattr(PyFuncObject *self, PyObject *name, PyObject *value)
; Set an arbitrary attribute on a function object.
; Lazily creates func_dict on first use.
; rdi = function, rsi = name, rdx = value
; ---------------------------------------------------------------------------
DEF_FUNC func_setattr
    push rbx
    push r12
    push r13
    push r14

    mov rbx, rdi            ; rbx = func
    mov r12, rsi            ; r12 = name
    mov r13, rdx            ; r13 = value
    mov r14d, ecx           ; r14d = value_tag (from caller)

    ; Check for __kwdefaults__
    lea rdi, [rel fn_attr_kwdefaults]
    lea rsi, [r12 + PyStrObject.data]
    call ap_strcmp
    test eax, eax
    jz .set_kwdefaults

    ; Check if func_dict exists
    mov rdi, [rbx + PyFuncObject.func_dict]
    test rdi, rdi
    jnz .have_dict

    ; Create func_dict lazily
    call dict_new
    mov [rbx + PyFuncObject.func_dict], rax
    mov rdi, rax

.have_dict:
    ; dict_set(func_dict, name, value, value_tag, key_tag)
    mov rsi, r12
    mov rdx, r13
    mov ecx, r14d           ; value_tag from caller
    mov r8d, TAG_PTR        ; key_tag (name is always heap string)
    call dict_set

    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.set_kwdefaults:
    ; XDECREF old kwdefaults
    mov rdi, [rbx + PyFuncObject.func_kwdefaults]
    test rdi, rdi
    jz .no_old_kwd
    call obj_decref
.no_old_kwd:
    ; Store new kwdefaults — INCREF if pointer, store NULL if non-pointer
    test r14d, TAG_RC_BIT
    jz .store_kwd_null
    mov rdi, r13
    call obj_incref
    mov [rbx + PyFuncObject.func_kwdefaults], r13
    jmp .setattr_done
.store_kwd_null:
    mov qword [rbx + PyFuncObject.func_kwdefaults], 0
.setattr_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC func_setattr

; ---------------------------------------------------------------------------
; func_getattr(PyFuncObject *self, PyObject *name) -> PyObject* or NULL
; Get an attribute from a function. Checks func_dict for arbitrary attrs.
; rdi = function, rsi = name
; ---------------------------------------------------------------------------
extern ap_strcmp
DEF_FUNC func_getattr
    push rbx
    push r12

    mov rbx, rdi            ; rbx = func
    mov r12, rsi            ; r12 = name

    ; Check for __name__
    lea rdi, [rel fn_attr_name]
    lea rsi, [r12 + PyStrObject.data]
    call ap_strcmp
    test eax, eax
    jz .return_name

    ; Check for __qualname__
    lea rdi, [rel fn_attr_qualname]
    lea rsi, [r12 + PyStrObject.data]
    call ap_strcmp
    test eax, eax
    jz .return_qualname

    ; Check for __kwdefaults__
    lea rdi, [rel fn_attr_kwdefaults]
    lea rsi, [r12 + PyStrObject.data]
    call ap_strcmp
    test eax, eax
    jz .return_kwdefaults

    ; Check for __code__
    lea rdi, [rel fn_attr_code]
    lea rsi, [r12 + PyStrObject.data]
    call ap_strcmp
    test eax, eax
    jz .return_code

    ; Check for __dict__
    lea rdi, [rel fn_attr_dict]
    lea rsi, [r12 + PyStrObject.data]
    call ap_strcmp
    test eax, eax
    jz .return_dict

    ; Check func_dict for arbitrary attrs
    mov rdi, [rbx + PyFuncObject.func_dict]
    test rdi, rdi
    jz .not_found

    mov rsi, r12
    mov edx, TAG_PTR
    call dict_get
    test edx, edx
    jz .not_found

    ; Found in dict - INCREF and return (rdx = tag from dict_get)
    INCREF_VAL rax, rdx
    pop r12
    pop rbx
    leave
    ret

.return_name:
    mov rax, [rbx + PyFuncObject.func_name]
    INCREF rax
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

.return_qualname:
    ; Get co_qualname from the code object
    mov rax, [rbx + PyFuncObject.func_code]
    mov rax, [rax + PyCodeObject.co_qualname]
    test rax, rax
    jz .return_name          ; fall back to __name__ if no qualname
    INCREF rax
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

.return_dict:
    mov rax, [rbx + PyFuncObject.func_dict]
    test rax, rax
    jnz .return_dict_obj
    ; Create empty dict if none exists
    call dict_new
    mov [rbx + PyFuncObject.func_dict], rax
.return_dict_obj:
    INCREF rax
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

.return_code:
    mov rax, [rbx + PyFuncObject.func_code]
    INCREF rax
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

.return_kwdefaults:
    mov rax, [rbx + PyFuncObject.func_kwdefaults]
    test rax, rax
    jnz .return_kwdefaults_obj
    ; Return None if no kwdefaults
    xor eax, eax
    mov edx, TAG_NONE
    pop r12
    pop rbx
    leave
    ret
.return_kwdefaults_obj:
    INCREF rax
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

.not_found:
    RET_NULL
    pop r12
    pop rbx
    leave
    ret
END_FUNC func_getattr

; ---------------------------------------------------------------------------
; func_repr(PyFuncObject *self) -> PyStrObject*
; Returns the string "<function>"
; rdi = function object
; ---------------------------------------------------------------------------
DEF_FUNC_BARE func_repr
    lea rdi, [rel func_repr_str]
    jmp str_from_cstr
END_FUNC func_repr

; ---------------------------------------------------------------------------
; raise_too_many_positional(PyFuncObject *func, int nargs_given)
; Raise TypeError with CPython-format message:
;   "qualname() takes N positional arguments but M were given"
;   or "qualname() takes from N to M positional arguments but K were given"
; rdi = func, esi = nargs_given
; Does not return.
; ---------------------------------------------------------------------------
RTMP_BUF  equ 256
RTMP_FRAME equ RTMP_BUF + 24
DEF_FUNC raise_too_many_positional, RTMP_FRAME
    push rbx
    push r12
    mov rbx, rdi               ; func
    mov r12d, esi              ; nargs_given

    ; Get qualname C-string
    mov rax, [rbx + PyFuncObject.func_code]
    mov rdi, [rax + PyCodeObject.co_qualname]
    test rdi, rdi
    jnz .rtmp_have_name
    mov rdi, [rbx + PyFuncObject.func_name]
.rtmp_have_name:
    lea rsi, [rdi + PyStrObject.data]   ; rsi = qualname cstr

    ; Get code object stats
    mov rdi, [rbx + PyFuncObject.func_code]
    mov eax, [rdi + PyCodeObject.co_argcount]
    ; eax = max positional args

    ; Compute min_args = co_argcount - len(func_defaults)
    mov ecx, eax               ; ecx = max_args
    mov rdi, [rbx + PyFuncObject.func_defaults]
    test rdi, rdi
    jz .rtmp_no_defaults
    mov edx, [rdi + PyTupleObject.ob_size]
    sub ecx, edx               ; ecx = min_args
    test ecx, ecx
    jns .rtmp_have_min
    xor ecx, ecx              ; clamp to 0
    jmp .rtmp_have_min
.rtmp_no_defaults:
    mov ecx, eax               ; min = max (no defaults)
.rtmp_have_min:
    ; ecx = min_args, eax = max_args, r12d = given, rsi = qualname cstr

    ; Build message in stack buffer [rbp - RTMP_BUF]
    lea rdi, [rbp - RTMP_BUF]
    push rax                   ; save max_args
    push rcx                   ; save min_args

    ; Copy qualname
.rtmp_copy_name:
    mov al, [rsi]
    test al, al
    jz .rtmp_name_done
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .rtmp_copy_name
.rtmp_name_done:

    ; Append "() takes "
    mov dword [rdi], '() t'
    mov dword [rdi+4], 'akes'
    mov byte [rdi+8], ' '
    add rdi, 9

    pop rcx                    ; min_args
    pop rax                    ; max_args

    cmp ecx, eax
    je .rtmp_exact_count

    ; "from {min} to {max} "
    mov dword [rdi], 'from'
    mov byte [rdi+4], ' '
    add rdi, 5
    push rax                   ; save max
    mov eax, ecx               ; min_args
    call .rtmp_itoa
    mov dword [rdi], ' to '
    add rdi, 4
    pop rax                    ; max_args
    call .rtmp_itoa
    jmp .rtmp_msg_cont

.rtmp_exact_count:
    ; Just "{max} "
    call .rtmp_itoa

.rtmp_msg_cont:
    ; " positional argument(s) but {given} were given"
    ; Check singular/plural
    push rdi
    lea rsi, [rel rtmp_pos_args]
    call .rtmp_strcpy
    pop rdi
    add rdi, rax               ; advance by length

    mov eax, r12d              ; given
    call .rtmp_itoa

    ; " were given" or " was given"
    cmp r12d, 1
    je .rtmp_was
    push rdi
    lea rsi, [rel rtmp_were_given]
    call .rtmp_strcpy
    pop rdi
    add rdi, rax
    jmp .rtmp_finish

.rtmp_was:
    push rdi
    lea rsi, [rel rtmp_was_given]
    call .rtmp_strcpy
    pop rdi
    add rdi, rax

.rtmp_finish:
    mov byte [rdi], 0          ; null terminate

    ; Raise TypeError with buffer
    extern exc_TypeError_type
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rbp - RTMP_BUF]
    call raise_exception

; Mini itoa: convert eax to decimal at [rdi], advance rdi
.rtmp_itoa:
    push rbx
    push rcx
    test eax, eax
    jnz .rtmp_itoa_nonzero
    mov byte [rdi], '0'
    inc rdi
    pop rcx
    pop rbx
    ret
.rtmp_itoa_nonzero:
    ; Handle negative
    test eax, eax
    jns .rtmp_itoa_pos
    mov byte [rdi], '-'
    inc rdi
    neg eax
.rtmp_itoa_pos:
    ; Push digits in reverse
    xor ecx, ecx              ; digit count
    mov ebx, 10
.rtmp_itoa_div:
    xor edx, edx
    div ebx
    add dl, '0'
    push rdx
    inc ecx
    test eax, eax
    jnz .rtmp_itoa_div
    ; Pop digits in order
.rtmp_itoa_pop:
    pop rax
    mov [rdi], al
    inc rdi
    dec ecx
    jnz .rtmp_itoa_pop
    pop rcx
    pop rbx
    ret

; Mini strcpy: copy rsi to [rdi], return length in rax
.rtmp_strcpy:
    xor eax, eax
.rtmp_strcpy_loop:
    mov cl, [rsi + rax]
    test cl, cl
    jz .rtmp_strcpy_done
    mov [rdi + rax], cl
    inc rax
    jmp .rtmp_strcpy_loop
.rtmp_strcpy_done:
    ret

END_FUNC raise_too_many_positional

section .rodata
rtmp_pos_args:     db " positional arguments but ", 0
rtmp_were_given:   db " were given", 0
rtmp_was_given:    db " was given", 0

section .text

; ---------------------------------------------------------------------------
; Data section
; ---------------------------------------------------------------------------
section .data

func_name_str:  db "function", 0
func_repr_str:  db "<function>", 0
fn_attr_name:   db "__name__", 0
fn_attr_dict:   db "__dict__", 0
fn_attr_code:   db "__code__", 0
fn_attr_kwdefaults: db "__kwdefaults__", 0
fn_attr_qualname: db "__qualname__", 0

; func_type - Type object for function objects
align 8
global func_type
func_type:
    dq 1                    ; ob_refcnt (immortal)
    dq type_type            ; ob_type
    dq func_name_str        ; tp_name
    dq PyFuncObject_size    ; tp_basicsize
    dq func_dealloc         ; tp_dealloc
    dq func_repr            ; tp_repr
    dq func_repr            ; tp_str
    dq 0                    ; tp_hash
    dq func_call            ; tp_call
    dq func_getattr         ; tp_getattr
    dq func_setattr         ; tp_setattr
    dq 0                    ; tp_richcompare
    dq 0                    ; tp_iter
    dq 0                    ; tp_iternext
    dq 0                    ; tp_init
    dq 0                    ; tp_new
    dq 0                    ; tp_as_number
    dq 0                    ; tp_as_sequence
    dq 0                    ; tp_as_mapping
    dq 0                    ; tp_base
    dq 0                    ; tp_dict
    dq 0                    ; tp_mro
    dq TYPE_FLAG_HAVE_GC                    ; tp_flags
    dq 0                    ; tp_bases
    dq func_traverse                        ; tp_traverse
    dq func_clear                        ; tp_clear
