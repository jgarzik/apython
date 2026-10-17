; func.asm - Functions, closures, and the cells they close over
;
; A cell is not a user-visible type; it exists only because a function
; needs somewhere to put a free variable, so it lives with the code that
; builds closures.
; Implements PyFuncObject: creation, calling, deallocation, and type descriptor

%include "macros.inc"
%include "object.inc"
%include "opcodes.inc"

extern none_singleton
extern ap_malloc
extern gc_alloc
extern gc_track
extern gc_dealloc
extern obj_decref
extern obj_incref
extern obj_dealloc
extern str_from_cstr
extern eval_frame
extern frame_new
extern frame_free
extern tuple_new
extern tuple_type
extern type_is_subtype
extern dict_type
extern code_type
extern type_type
extern exc_TypeError_type
extern exc_ValueError_type
extern rbt_append_cstr
extern raise_exception

;; ============================================================================
;; func_new(PyCodeObject *code, PyObject *globals) -> PyFuncObject*
;; Allocate and initialize a new function object.
;; rdi = code object, rsi = globals dict
;; ============================================================================
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

    ; __qualname__ and __doc__ start empty and fall back to the code object;
    ; an assignment fills them in, and it must not land in func_dict.
    mov qword [r13 + PyFuncObject.func_qualname], 0
    mov qword [r13 + PyFuncObject.func_doc], 0
    ; No annotations until MAKE_FUNCTION hands some over.
    mov qword [r13 + PyFuncObject.func_annotations], 0
    mov qword [r13 + PyFuncObject.func_module], 0

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

;; ============================================================================
;; func_call(PyFuncObject *callable, PyObject **args_ptr, int nargs) -> PyObject*
;; tp_call implementation for function objects.
;; rdi = function object, rsi = pointer to args array, edx = nargs
;;
;; r12 still holds the CALLER's frame pointer (callee-saved, set by eval loop,
;; preserved through op_call).
;;
;; Full argument binding following CPython initialize_locals:
;;   1. Create **kwargs dict if CO_VARKEYWORDS
;;   2. Copy positional args
;;   3. Handle *args (CO_VARARGS)
;;   4. Match keyword args (from kw_names_pending)
;;   5. Apply positional defaults (func_defaults)
;;   6. Apply kw-only defaults (func_kwdefaults)
;; ============================================================================
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

    ; === The shape almost every call has ===
    ; N positional arguments, exactly filling N parameters: no keywords, no
    ; *args, no **kwargs, no keyword-only parameters.  The six binder phases
    ; below all reduce to the copy loop for it, and two of them reload
    ; func_code from memory to decide they have nothing to do.  Phase 6.5 is
    ; worse than nothing here: it walks the very slots the copy loop just
    ; filled, to check that they are filled.
    ;
    ; Defaults need no test.  Every parameter has an argument, so a default
    ; could not apply to one.
    ;
    ; rdi = func_code, eax = co_argcount, ecx = positional_count.
    cmp qword [rsp+0], 0
    jne .general_binder                 ; keywords were passed
    cmp ecx, eax
    jne .general_binder                 ; not an exact fill
    cmp dword [rdi + PyCodeObject.co_kwonlyargcount], 0
    jne .general_binder
    test dword [rdi + PyCodeObject.co_flags], CO_VARARGS | CO_VARKEYWORDS
    jnz .general_binder

    extern builtins_dict_global
    mov rdx, [rel builtins_dict_global]
    mov rsi, [rbx + PyFuncObject.func_globals]
    xor ecx, ecx
    call frame_new                      ; rdi is already func_code
    mov r12, rax
    mov [r12 + PyFrame.func_obj], rbx

    mov ecx, r15d                       ; nargs, and every parameter's argument
    test ecx, ecx
    jz .args_valid
    xor eax, eax
.fast_bind:
    mov r8, rax
    shl r8, 3                           ; localsplus at 8-byte stride
    mov rdx, [r14 + r8]
    INCREF_V rdx, r9
    mov [r12 + PyFrame.localsplus + r8], rdx
    inc eax
    cmp eax, ecx
    jb .fast_bind
    jmp .args_valid

.general_binder:
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
    mov [r12 + PyFrame.localsplus + rcx], rax   ; a dict pointer is its own Value

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
    mov rdx, [r14 + r8]            ; the argument Value
    INCREF_V rdx, r9
    mov [r12 + PyFrame.localsplus + r8], rdx
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
    shl r10, 3                      ; one Value per argument slot
    mov r9, [r14 + r10]             ; the argument Value
    mov r10, [rax + PyTupleObject.ob_item]
    INCREF_V r9, r11
    mov [r10 + rsi * 8], r9
    inc esi
    jmp .fill_varargs

.store_varargs:
    mov r11, rdx
    shl rdx, 3                 ; localsplus 8 bytes/slot
    mov [r12 + PyFrame.localsplus + rdx], rax   ; a tuple pointer is its own Value
    jmp .varargs_done

.empty_varargs:
    push rax                    ; save slot index
    xor edi, edi
    call tuple_new
    pop rdx                     ; rdx = slot index
    mov r11, rdx
    shl rdx, 3                 ; localsplus 8 bytes/slot
    mov [r12 + PyFrame.localsplus + rdx], rax   ; a tuple pointer is its own Value

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
    cmp qword [r12 + PyFrame.localsplus + r10*8], 0
    jne .defaults_next

    ; Must have a default (i >= m)
    movsxd r8, edi
    cmp r8, rsi
    jl .defaults_next

    ; defaults[i - m]
    mov r8, rdi
    sub r8, rsi
    mov r9, [rax + PyTupleObject.ob_item]       ; payloads
    mov r9, [r9 + r8*8]                          ; payload
    V_UNPACK r9, r10
    movsxd r8, edi
    mov r11, r8
    shl r8, 3                  ; localsplus 8 bytes/slot
    INCREF_VAL r9, r10
    V_PACK r9, r10
    mov [r12 + PyFrame.localsplus + r8], r9

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
    cmp qword [r12 + PyFrame.localsplus + r8*8], 0
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
    call dict_get
    V_UNPACK rax, rdx           ; dict_get returns a Value

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
    INCREF_VAL r8, r10
    V_PACK r8, r10
    mov [r12 + PyFrame.localsplus + r9], r8

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
    cmp qword [r12 + PyFrame.localsplus + r8*8], 0
    je .args_missing
    inc esi
    jmp .check_args_loop
.args_missing:
    ; The names of what is missing come out of the frame's empty slots, so
    ; the raiser frees the frame rather than the caller.
    mov rdi, rbx
    mov rsi, r12
    extern raise_missing_arguments
    call raise_missing_arguments
.args_valid:
    ; === Phase 7: Call eval_frame ===
    mov rdi, r12
    call eval_frame
    ; eval_frame returns a Value and func_call returns a Value.  This used to
    ; V_UNPACK it, spill both halves into two frame slots across the frame
    ; free, reload both, and V_PACK it again -- a full classify and re-encode
    ; on every Python function call, of a word that was never anything else.
    mov [rsp+16], rax       ; park the return Value across frame_free

    ; Free the frame (unless generator owns it: instr_ptr != 0)
    cmp qword [r12 + PyFrame.instr_ptr], 0
    jne .skip_frame_free
    mov rdi, r12
    call frame_free
.skip_frame_free:

    mov rax, [rsp+16]       ; the return Value

    add rsp, 56
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC func_call

;; ============================================================================
;; func_bind_kwargs - Bind keyword arguments to frame locals
;;
;; rdi = function object
;; rsi = frame
;; rdx = args_ptr
;; ecx = positional_count
;; r8  = kw_names tuple (NOT NULL)
;; r9  = kwargs_dict (or NULL if no CO_VARKEYWORDS)
;; ============================================================================
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
    ; Check if slot already filled (would be "multiple values" error)
    cmp qword [r12 + PyFrame.localsplus + rdx*8], 0
    jne .kw_next            ; skip silently (TODO: error)

    ; Assign: localsplus[j] = args[value_index], INCREF
    mov rax, [rsp+24]
    mov rdi, [r13 + rax*8]    ; the argument Value
    INCREF_V rdi, rsi
    mov [r12 + PyFrame.localsplus + rdx*8], rdi
    jmp .kw_next

.kw_not_found:
    ; Add to **kwargs if available
    mov rdi, [rsp+0]
    test rdi, rdi
    jz .kw_unexpected       ; no **kwargs, raise TypeError

    ; dict_set(kwargs_dict, key Value, value Value)
    mov rax, [rsp+16]
    mov rsi, [r14 + PyTupleObject.ob_item]
    mov rsi, [rsi + rax*8]         ; key = kw_name (already a Value)
    mov rax, [rsp+24]
    mov rdx, [r13 + rax*8]         ; the value Value
    call dict_set
    jmp .kw_next

.kw_unexpected:
    ; "h() got an unexpected keyword argument 'nosuch'"; frees the frame
    mov rax, [rsp+16]
    mov rdx, [r14 + PyTupleObject.ob_item]
    mov rdx, [rdx + rax*8]         ; the keyword's name
    mov rdi, rbx
    mov rsi, r12
    extern raise_unexpected_keyword
    call raise_unexpected_keyword

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

;; ============================================================================
;; func_dealloc(PyFuncObject *self)
;; Releases references to internal objects and frees the function.
;; rdi = function object
;; ============================================================================
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
    mov rdi, [rbx + PyFuncObject.func_qualname]
    test rdi, rdi
    jz .no_func_qualname
    DECREF_V rdi, rcx
.no_func_qualname:
    mov rdi, [rbx + PyFuncObject.func_doc]
    test rdi, rdi
    jz .no_func_doc
    DECREF_V rdi, rcx
.no_func_doc:
    mov rdi, [rbx + PyFuncObject.func_annotations]
    test rdi, rdi
    jz .no_func_annos
    call obj_decref
.no_func_annos:
    mov rdi, [rbx + PyFuncObject.func_module]
    test rdi, rdi
    jz .no_func_module
    DECREF_V rdi, rcx
.no_func_module:

    ; Free the function object itself (GC-aware)
    mov rdi, rbx
    call gc_dealloc

    pop r12
    pop rbx
    leave
    ret
END_FUNC func_dealloc

;; ============================================================================
;; func_setattr(PyFuncObject *self, PyObject *name, PyObject *value)
;; Set an arbitrary attribute on a function object.
;; Lazily creates func_dict on first use.
;; rdi = function, rsi = name, rdx = value
;; ============================================================================
section .bss
;; Where the __code__ mismatch message is composed.
sc_msgbuf: resb 256
section .text

SC_WANT equ 8             ; free variables the new code object needs
SC_HAVE equ 16            ; free variables the function's closure has
SC_FRAME equ 16           ; + 4 pushes = 48, 16-aligned
DEF_FUNC func_setattr, SC_FRAME
    push rbx
    push r12
    push r13
    push r14

    mov rbx, rdi            ; rbx = func
    mov r12, rsi            ; r12 = name
    mov r13, rdx            ; r13 = value Value

    ; Check for __kwdefaults__
    lea rdi, [rel fn_attr_kwdefaults]
    lea rsi, [r12 + PyStrObject.data]
    call ap_strcmp
    test eax, eax
    jz .set_kwdefaults

    ; And __defaults__, which is the one that was missing.  Every attribute
    ; named in this function is here for the same reason -- func_getattr
    ; answers it from a FIELD, so an assignment that lands in func_dict reads
    ; back as whatever the `def` was written with.  For __defaults__ nothing
    ; raised and nothing took effect: `f.__defaults__ = (9,)` stored a dict
    ; entry nobody reads, `f.__defaults__` still answered None, and `f(1)`
    ; still wanted both arguments.  collections.namedtuple is built on
    ; exec() followed by `__new__.__defaults__ = tuple(defaults)`, so every
    ; namedtuple with a `defaults=` argument had none.
    lea rdi, [rel fn_attr_defaults]
    lea rsi, [r12 + PyStrObject.data]
    call ap_strcmp
    test eax, eax
    jz .set_defaults

    ; __name__ has a field of its own, and CPython keeps it there rather than
    ; in __dict__.  Storing it in func_dict like any other attribute was what
    ; made `f.__name__ = "x"` read back as the old name: func_getattr answered
    ; from the field without ever looking.
    lea rdi, [rel fn_attr_name]
    lea rsi, [r12 + PyStrObject.data]
    call ap_strcmp
    test eax, eax
    jz .set_name

    ; __qualname__ and __doc__ have fields of their own for the same reason.
    ; They used to land in func_dict, so f.__dict__ was non-empty after
    ; functools.wraps -- CPython keeps both on the function and leaves the
    ; dict alone until something else is assigned.
    lea rdi, [rel fn_attr_qualname]
    lea rsi, [r12 + PyStrObject.data]
    call ap_strcmp
    test eax, eax
    jz .set_qualname

    lea rdi, [rel fn_attr_doc]
    lea rsi, [r12 + PyStrObject.data]
    call ap_strcmp
    test eax, eax
    jz .set_doc

    ; __module__ too: it was read from the globals every time, so an
    ; assignment landed in func_dict and was never read back.
    lea rdi, [rel fn_attr_module]
    lea rsi, [r12 + PyStrObject.data]
    call ap_strcmp
    test eax, eax
    jz .set_module

    ; So does __annotations__, and it has to go in the field rather than the
    ; dict: func_getattr answers from the field, so an assignment that landed
    ; in func_dict read back as the annotations the def was written with.
    lea rdi, [rel fn_attr_annotations]
    lea rsi, [r12 + PyStrObject.data]
    call ap_strcmp
    test eax, eax
    jz .set_annotations

    ; And __code__, which is how a decorator rewrites a function's body:
    ; `func.__code__ = co.replace(co_flags=...)` is types.coroutine, and the
    ; whole of asyncio is behind it.
    lea rdi, [rel fn_attr_code]
    lea rsi, [r12 + PyStrObject.data]
    call ap_strcmp
    test eax, eax
    jz .set_code

    ; Check if func_dict exists
    mov rdi, [rbx + PyFuncObject.func_dict]
    test rdi, rdi
    jnz .have_dict

    ; Create func_dict lazily
    call dict_new
    mov [rbx + PyFuncObject.func_dict], rax
    mov rdi, rax

.have_dict:
    ; dict_set(func_dict, name Value, value Value)
    mov rsi, r12
    mov rdx, r13
    call dict_set

    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.set_qualname:
    ; A string, as CPython requires -- and it may be deleted, which restores
    ; the code object's own.
    test r13, r13
    jz .sq_store
    mov rdi, r13
    V_TEST_PTR rdi, rax
    ja .sq_type
    mov rax, [rdi + PyObject.ob_type]
    REQUIRE_STR_TYPE rax, rcx, .sq_type
.sq_store:
    INCREF_V r13, rax
    mov rax, [rbx + PyFuncObject.func_qualname]
    mov [rbx + PyFuncObject.func_qualname], r13
    test rax, rax
    jz .sq_done
    mov rdi, rax
    DECREF_V rdi, rcx
.sq_done:
    xor eax, eax
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
.sq_type:
    RAISE exc_TypeError_type, "__qualname__ must be set to a string object"

.set_code:
    ; A code object, and only a code object: everything that reads func_code
    ; reads its fields without checking.
    test r13, r13
    jz .sc_type
    mov rdi, r13
    V_TEST_PTR rdi, rax
    ja .sc_type
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel code_type]
    cmp rax, rcx
    jne .sc_type

    ; And one that closes over the same number of names.  The closure tuple
    ; belongs to the FUNCTION and COPY_FREE_VARS copies it into the frame by
    ; the new code's count, so a code object with more free variables reads
    ; past the tuple and increfs whatever is after it.  CPython checks the
    ; two counts and refuses; so does this, with its wording.
    mov rdi, r13
    call func_free_count
    mov [rbp - SC_WANT], rax
    mov qword [rbp - SC_HAVE], 0
    mov rdi, [rbx + PyFuncObject.func_code]
    test rdi, rdi
    jz .sc_counts_ok
    call func_free_count
    mov [rbp - SC_HAVE], rax
    cmp rax, [rbp - SC_WANT]
    jne .sc_freevars
.sc_counts_ok:
    mov rdi, r13
    call obj_incref
    mov rax, [rbx + PyFuncObject.func_code]
    mov [rbx + PyFuncObject.func_code], r13
    test rax, rax
    jz .sc_done
    mov rdi, rax
    call obj_decref
.sc_done:
    xor eax, eax
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
.sc_type:
    RAISE exc_TypeError_type, "__code__ must be set to a code object"
.sc_freevars:
    ; CPython names the function and both counts, which is the whole of what
    ; makes the message actionable: "k() requires a code object with 1 free
    ; vars, not 2".
    lea rdi, [rel sc_msgbuf]
    mov rsi, [rbx + PyFuncObject.func_name]
    test rsi, rsi
    jz .scf_no_name
    lea rsi, [rsi + PyStrObject.data]
    jmp .scf_have_name
.scf_no_name:
    CSTRING rsi, "function"
.scf_have_name:
    call rbt_append_cstr
    mov rdi, rax
    CSTRING rsi, "() requires a code object with "
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - SC_HAVE]
    call sc_append_num
    mov rdi, rax
    CSTRING rsi, " free vars, not "
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - SC_WANT]
    call sc_append_num
    lea rsi, [rel sc_msgbuf]
    lea rdi, [rel exc_ValueError_type]
    call raise_exception
    ud2

.set_annotations:
    ; A mapping, as CPython requires; what it stores is whatever it is given,
    ; and func_getattr only folds a TUPLE, so a dict assigned here comes back
    ; unchanged.
    test r13, r13
    jz .sa_type
    mov rdi, r13
    V_TEST_PTR rdi, rax
    ja .sa_type
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel dict_type]
    cmp rax, rcx
    jne .sa_type
    INCREF_V r13, rax
    mov rax, [rbx + PyFuncObject.func_annotations]
    mov [rbx + PyFuncObject.func_annotations], r13
    test rax, rax
    jz .sa_done
    mov rdi, rax
    call obj_decref
.sa_done:
    xor eax, eax
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
.sa_type:
    RAISE exc_TypeError_type, "__annotations__ must be set to a dict object"

.set_module:
    ; Anything, including None, as CPython's func_set_module takes; a delete
    ; stores None the way CPython's does rather than restoring the default.
    test r13, r13
    jnz .smod_have
    extern none_singleton
    lea r13, [rel none_singleton]
.smod_have:
    INCREF_V r13, rax
    mov rax, [rbx + PyFuncObject.func_module]
    mov [rbx + PyFuncObject.func_module], r13
    test rax, rax
    jz .sd_done
    mov rdi, rax
    DECREF_V rdi, rcx
    jmp .sd_done

.set_doc:
    ; __doc__ takes anything, including None, as CPython's does.
    INCREF_V r13, rax
    mov rax, [rbx + PyFuncObject.func_doc]
    mov [rbx + PyFuncObject.func_doc], r13
    test rax, rax
    jz .sd_done
    mov rdi, rax
    DECREF_V rdi, rcx
.sd_done:
    xor eax, eax
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.set_name:
    ; It must be a str; CPython raises for anything else.
    mov rdi, r13
    V_TEST_PTR rdi, rax
    ja .set_name_type_error
    mov rax, [rdi + PyObject.ob_type]
    REQUIRE_STR_TYPE rax, rcx, .set_name_type_error
    mov rdi, [rbx + PyFuncObject.func_name]
    mov rax, r13
    INCREF rax
    mov [rbx + PyFuncObject.func_name], rax
    test rdi, rdi
    jz .set_name_done
    call obj_decref
.set_name_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.set_name_type_error:
    RAISE exc_TypeError_type, "__name__ must be set to a string object"

.set_defaults:
    ; A delete arrives as a NULL Value, and None means the same thing: no
    ; defaults.  Everything else must be a tuple -- CPython's setter says so,
    ; and with no setter at all a list was accepted in silence.
    test r13, r13
    jz .set_defaults_clear
    lea rax, [rel none_singleton]
    cmp r13, rax
    je .set_defaults_clear
    ; An int or float immediate is not a tuple either, and dereferencing one
    ; to read ob_type would read the number.
    V_TEST_PTR r13, r14
    ja .set_defaults_type_error
    mov rax, [r13 + PyObject.ob_type]
    lea rcx, [rel tuple_type]
    cmp rax, rcx
    je .set_defaults_store
    ; A tuple SUBCLASS is accepted, because CPython's PyTuple_Check is.
    mov rdi, rax
    mov rsi, rcx
    call type_is_subtype
    test eax, eax
    jz .set_defaults_type_error
.set_defaults_store:
    mov rdi, r13
    call obj_incref
    mov rdi, [rbx + PyFuncObject.func_defaults]
    mov [rbx + PyFuncObject.func_defaults], r13
    test rdi, rdi
    jz .setattr_done
    call obj_decref
    jmp .setattr_done

.set_defaults_clear:
    mov rdi, [rbx + PyFuncObject.func_defaults]
    mov qword [rbx + PyFuncObject.func_defaults], 0
    test rdi, rdi
    jz .setattr_done
    call obj_decref
    jmp .setattr_done

.set_defaults_type_error:
    RAISE exc_TypeError_type, "__defaults__ must be set to a tuple object"

.set_kwdefaults:
    ; func_call reads this field with dict_get, so whatever is here has to be
    ; a dict or NULL and nothing else.  The test used to be only "is it a
    ; heap pointer", which None and a list both pass -- so
    ; `f.__kwdefaults__ = None` and `f.__kwdefaults__ = [1]` each stored an
    ; object dict_get then read as a dict header, and a plain assignment
    ; segfaulted.  CPython maps both NULL and None to "no kw-only defaults"
    ; and refuses anything that is not a dict.
    test r13, r13
    jz .set_kwd_clear
    lea rax, [rel none_singleton]
    cmp r13, rax
    je .set_kwd_clear
    ; An int or float immediate has no ob_type to read.
    V_TEST_PTR r13, r14
    ja .set_kwd_type_error
    mov rax, [r13 + PyObject.ob_type]
    lea rcx, [rel dict_type]
    cmp rax, rcx
    je .set_kwd_store
    ; A dict SUBCLASS is accepted, because CPython's PyDict_Check is.
    mov rdi, rax
    mov rsi, rcx
    call type_is_subtype
    test eax, eax
    jz .set_kwd_type_error
.set_kwd_store:
    ; Store first, release second: the old value and the new one can be the
    ; same object, and releasing it before the store would free what is
    ; about to be installed.
    mov rdi, r13
    call obj_incref
    mov rdi, [rbx + PyFuncObject.func_kwdefaults]
    mov [rbx + PyFuncObject.func_kwdefaults], r13
    test rdi, rdi
    jz .setattr_done
    call obj_decref
    jmp .setattr_done

.set_kwd_clear:
    mov rdi, [rbx + PyFuncObject.func_kwdefaults]
    mov qword [rbx + PyFuncObject.func_kwdefaults], 0
    test rdi, rdi
    jz .setattr_done
    call obj_decref
    jmp .setattr_done

.set_kwd_type_error:
    RAISE exc_TypeError_type, "__kwdefaults__ must be set to a dict object"

.setattr_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC func_setattr


;; ============================================================================
;; sc_append_num(rdi = dest, rsi = a small count) -> rax = the NUL it wrote
;; Decimal, for the __code__ message; the counts are small by construction.
;; ============================================================================
SAN_END   equ 8            ; the NUL the digits are written back from
SAN_FRAME equ 32           ; + 0 pushes = 32, 16-aligned
DEF_FUNC_LOCAL sc_append_num, SAN_FRAME
    mov rax, rsi
    lea rcx, [rbp - SAN_END]
    mov byte [rcx], 0
.san_loop:
    xor edx, edx
    mov r8d, 10
    div r8
    add dl, '0'
    dec rcx
    mov [rcx], dl
    test rax, rax
    jnz .san_loop
    mov rsi, rcx
    call rbt_append_cstr
    leave
    ret
END_FUNC sc_append_num

;; ============================================================================
;; func_free_count(rdi = a code object) -> rax = how many free variables it has
;;
;; The count CO_FAST_FREE marks in co_localspluskinds, which is what
;; COPY_FREE_VARS copies out of the function's closure tuple.
;; ============================================================================
DEF_FUNC_LOCAL func_free_count
    xor eax, eax
    mov rcx, [rdi + PyCodeObject.co_localspluskinds]
    test rcx, rcx
    jz .ffc_done
    mov rsi, [rcx + PyBytesObject.ob_size]
    xor edx, edx
.ffc_scan:
    cmp rdx, rsi
    jae .ffc_done
    movzx r8d, byte [rcx + PyBytesObject.data + rdx]
    test r8d, CO_FAST_FREE
    jz .ffc_next
    inc rax
.ffc_next:
    inc rdx
    jmp .ffc_scan
.ffc_done:
    leave
    ret
END_FUNC func_free_count

;; ============================================================================
;; func_getattr(PyFuncObject *self, PyObject *name) -> PyObject* or NULL
;; Get an attribute from a function. Checks func_dict for arbitrary attrs.
;; rdi = function, rsi = name
;; ============================================================================
extern ap_strcmp
extern str_type
extern str_from_cstr_heap
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

    ; Check for __defaults__
    lea rdi, [rel fn_attr_defaults]
    lea rsi, [r12 + PyStrObject.data]
    call ap_strcmp
    test eax, eax
    jz .return_defaults

    ; Check for __closure__
    lea rdi, [rel fn_attr_closure]
    lea rsi, [r12 + PyStrObject.data]
    call ap_strcmp
    test eax, eax
    jz .return_closure

    ; Check for __globals__
    lea rdi, [rel fn_attr_globals]
    lea rsi, [r12 + PyStrObject.data]
    call ap_strcmp
    test eax, eax
    jz .return_globals

    ; Check for __doc__
    lea rdi, [rel fn_attr_doc]
    lea rsi, [r12 + PyStrObject.data]
    call ap_strcmp
    test eax, eax
    jz .return_doc

    ; Check for __module__
    lea rdi, [rel fn_attr_module]
    lea rsi, [r12 + PyStrObject.data]
    call ap_strcmp
    test eax, eax
    jz .return_module

    ; Check for __annotations__
    lea rdi, [rel fn_attr_annotations]
    lea rsi, [r12 + PyStrObject.data]
    call ap_strcmp
    test eax, eax
    jz .return_annotations

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
    call dict_get
    V_UNPACK rax, rdx           ; dict_get returns a Value
    test edx, edx
    jz .not_found

    ; Found in dict - INCREF and return (rdx = tag from dict_get)
    INCREF_VAL rax, rdx
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.return_name:
    ; An assignment wins, as it does for __doc__: `f.__name__ = "x"` is stored
    ; in func_dict like any other attribute, and reading func_name past it made
    ; the assignment look like a no-op.  functools.wraps writes both this and
    ; __qualname__ that way.
    call .fg_from_dict
    test rax, rax
    jnz .return_ptr_attr
    mov rax, [rbx + PyFuncObject.func_name]
    INCREF rax
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.return_qualname:
    ; The field first, then the dict -- functools.wraps writes __qualname__
    ; through setattr, which fills the field now, and older code that reached
    ; into f.__dict__ directly still works.
    mov rax, [rbx + PyFuncObject.func_qualname]
    test rax, rax
    jnz .return_ptr_attr
    call .fg_from_dict
    test rax, rax
    jnz .return_ptr_attr
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
    V_PACK rax, rdx             ; return one Value
    ret

.return_annotations:
    ; MAKE_FUNCTION hands them over as a TUPLE of alternating name and value,
    ; which is what the compiler builds and what costs nothing when nobody
    ; asks.  Reading the attribute is where it becomes a dict, and the dict
    ; is stored back: `f.__annotations__["x"] = int` has to stick, and
    ; typing.get_type_hints reads it more than once.
    ;
    ; r13/r14/r15 are the caller's; this arm is the only one here that needs
    ; more than rbx and r12, so it saves and restores them itself.
    mov rax, [rbx + PyFuncObject.func_annotations]
    test rax, rax
    jz .fa_make_empty
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel tuple_type]
    cmp rcx, rdx
    jne .return_ptr_attr        ; folded already
    push r13
    push r14
    push r15
    mov r13, rax                ; the tuple
    call dict_new
    test rax, rax
    jz .fa_failed
    mov r14, rax                ; the dict
    xor r15d, r15d
.fa_pair:
    mov rax, [r13 + PyTupleObject.ob_size]
    lea rcx, [r15 + 1]
    cmp rcx, rax
    jge .fa_folded
    mov rax, [r13 + PyTupleObject.ob_item]
    mov rsi, [rax + r15*8]      ; the name
    mov rdx, [rax + r15*8 + 8]  ; the value
    mov rdi, r14
    call dict_set
    add r15, 2
    jmp .fa_pair
.fa_folded:
    mov [rbx + PyFuncObject.func_annotations], r14
    mov rdi, r13
    call obj_decref             ; the tuple, replaced by the dict
    mov rax, r14
    pop r15
    pop r14
    pop r13
    jmp .return_ptr_attr
.fa_failed:
    pop r15
    pop r14
    pop r13
    jmp .not_found

.fa_make_empty:
    ; A function written without annotations still answers a dict, and the
    ; same dict every time, because assigning into it is ordinary Python.
    call dict_new
    test rax, rax
    jz .not_found
    mov [rbx + PyFuncObject.func_annotations], rax
    jmp .return_ptr_attr

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
    V_PACK rax, rdx             ; return one Value
    ret

.return_defaults:
    ; The field was always there; nothing exposed it.
    mov rax, [rbx + PyFuncObject.func_defaults]
    jmp .return_or_none

.return_closure:
    mov rax, [rbx + PyFuncObject.func_closure]
    jmp .return_or_none

.return_globals:
    mov rax, [rbx + PyFuncObject.func_globals]
    jmp .return_or_none

.return_or_none:
    test rax, rax
    jnz .return_ptr_attr
    lea rax, [rel none_singleton]
.return_ptr_attr:
    INCREF rax
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

;; .fg_from_dict -> rax = the attribute out of func_dict, borrowed, or 0.
;; rbx = the function, r12 = the name.
.fg_from_dict:
    mov rdi, [rbx + PyFuncObject.func_dict]
    test rdi, rdi
    jz .fgfd_none
    mov rsi, r12
    call dict_get
    V_UNPACK rax, rdx
    test edx, edx
    jz .fgfd_none
    ret
.fgfd_none:
    xor eax, eax
    ret

.return_doc:
    ; An assignment wins over the source docstring.  It goes in the field now
    ; -- CPython keeps __doc__ on the function, so f.__dict__ stays empty --
    ; and the dict is still consulted after it, for anything that wrote there
    ; directly.  collections.namedtuple writes docstrings this way.
    mov rax, [rbx + PyFuncObject.func_doc]
    test rax, rax
    jz .doc_try_dict
    ; __doc__ takes any object, so the field holds a Value: f.__doc__ = 12345
    ; is legal, and an INCREF that dereferences it is a segfault.
    INCREF_V rax, rcx
    V_UNPACK rax, rdx
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.doc_try_dict:
    mov rdi, [rbx + PyFuncObject.func_dict]
    test rdi, rdi
    jz .doc_from_code
    mov rsi, r12
    call dict_get
    V_UNPACK rax, rdx
    test edx, edx
    jz .doc_from_code
    INCREF_VAL rax, rdx
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.doc_from_code:
    ; Otherwise a docstring is co_consts[0] when it is a string, exactly as
    ; CPython builds __doc__ at function creation.
    mov rax, [rbx + PyFuncObject.func_code]
    test rax, rax
    jz .doc_none
    mov rax, [rax + PyCodeObject.co_consts]
    test rax, rax
    jz .doc_none
    cmp qword [rax + PyTupleObject.ob_size], 0
    jle .doc_none
    mov rax, [rax + PyTupleObject.ob_item]
    mov rax, [rax]
    V_TEST_PTR rax, rcx
    ja .doc_none
    test rax, rax
    jz .doc_none
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    jne .doc_none
    jmp .return_ptr_attr
.doc_none:
    lea rax, [rel none_singleton]
    jmp .return_ptr_attr

.return_module:
    ; An assigned __module__ first; else the defining module's __name__, out
    ; of the function's globals.
    mov rax, [rbx + PyFuncObject.func_module]
    test rax, rax
    jz .module_default
    INCREF_V rax, rcx
    pop r12
    pop rbx
    leave
    ret
.module_default:
    mov rdi, [rbx + PyFuncObject.func_globals]
    test rdi, rdi
    jz .doc_none
    lea rdi, [rel fn_dunder_name_key]
    call str_from_cstr_heap
    push rax
    mov rdi, [rbx + PyFuncObject.func_globals]
    mov rsi, rax
    call dict_get
    V_UNPACK rax, rdx
    pop rdi
    push rax
    push rdx
    call obj_decref
    pop rdx
    pop rax
    test edx, edx
    jz .doc_none
    jmp .return_ptr_attr

.return_code:
    mov rax, [rbx + PyFuncObject.func_code]
    INCREF rax
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.return_kwdefaults:
    mov rax, [rbx + PyFuncObject.func_kwdefaults]
    test rax, rax
    jnz .return_kwdefaults_obj
    ; Return None if no kwdefaults
    xor eax, eax
    RET_NONE
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret
.return_kwdefaults_obj:
    INCREF rax
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret

.not_found:
    RET_NULL
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; return one Value
    ret
END_FUNC func_getattr

;; ============================================================================
;; func_repr(PyFuncObject *self) -> PyStrObject*
;; "<function NAME at 0x...>", with NAME the qualified name -- which is what
;; tells `f` from `C.m` and both from `<lambda>`.  It used to be the fixed
;; string "<function>".
;; rdi = function object
;; ============================================================================
DEF_FUNC func_repr, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    mov rax, [rbx + PyFuncObject.func_qualname]
    test rax, rax
    jnz .fr_have_name
    mov rax, [rbx + PyFuncObject.func_code]
    test rax, rax
    jz .fr_no_name
    mov rax, [rax + PyCodeObject.co_qualname]
    test rax, rax
    jnz .fr_have_name
    mov rax, [rbx + PyFuncObject.func_name]
    test rax, rax
    jz .fr_no_name
.fr_have_name:
    lea rdx, [rax + PyStrObject.data]
    jmp .fr_build
.fr_no_name:
    xor edx, edx
.fr_build:
    mov rdi, rbx
    lea rsi, [rel func_repr_str]
    extern obj_repr_named_at
    call obj_repr_named_at
    pop rbx
    leave
    ret
END_FUNC func_repr

;; ============================================================================
;; raise_too_many_positional(PyFuncObject *func, int nargs_given)
;; Raise TypeError with CPython-format message:
;;   "qualname() takes N positional arguments but M were given"
;;   or "qualname() takes from N to M positional arguments but K were given"
;; rdi = func, esi = nargs_given
;; Does not return.
;; ============================================================================
RTMP_BUF  equ 256
; Whether the count being reported is 1.  CPython pluralises "argument" on
; that count rather than unconditionally, so "takes 1 positional arguments"
; was wrong -- and only in the exact-count form: the "from N to M" wording is
; always plural.  A slot rather than a register, because this function's
; push list sets the frame's alignment.
RTMP_SINGULAR equ RTMP_BUF + 8
RTMP_FRAME equ RTMP_BUF + 24
DEF_FUNC raise_too_many_positional, RTMP_FRAME
    push rbx
    push r12
    mov rbx, rdi               ; func
    mov r12d, esi              ; nargs_given
    mov qword [rbp - RTMP_SINGULAR], 0

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
    cmp eax, 1
    jne .rtmp_exact_plural
    mov qword [rbp - RTMP_SINGULAR], 1
.rtmp_exact_plural:
    call .rtmp_itoa

.rtmp_msg_cont:
    ; " positional argument(s) but {given} were given"
    push rdi
    lea rsi, [rel rtmp_pos_args]
    cmp qword [rbp - RTMP_SINGULAR], 0
    je .rtmp_pos_plural
    lea rsi, [rel rtmp_pos_arg]
.rtmp_pos_plural:
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
rtmp_pos_arg:      db " positional argument but ", 0
rtmp_were_given:   db " were given", 0
rtmp_was_given:    db " was given", 0

section .text

;; ============================================================================
;; Data section
;; ============================================================================
section .data

func_name_str:  db "function", 0
func_repr_str:  db "function", 0
fn_attr_name:   db "__name__", 0
fn_attr_annotations: db "__annotations__", 0
fn_attr_dict:   db "__dict__", 0
fn_attr_code:   db "__code__", 0
fn_attr_kwdefaults: db "__kwdefaults__", 0
fn_attr_qualname: db "__qualname__", 0
fn_attr_defaults: db "__defaults__", 0
fn_attr_closure: db "__closure__", 0
fn_attr_globals: db "__globals__", 0
fn_attr_doc:    db "__doc__", 0
fn_attr_module: db "__module__", 0
fn_dunder_name_key: db "__name__", 0

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
    dq func_construct        ; tp_new
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
    dq 0       ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

;; ============================================================================
;; (was src/pyo/cell.asm)
;; ============================================================================

section .text

extern ap_malloc
extern gc_alloc
extern gc_track
extern gc_dealloc
extern obj_incref
extern obj_dealloc
extern str_from_cstr
extern type_type

;; ============================================================================
;; cell_new(rdi = contents Value) -> PyCellObject*
;; Create a new cell holding the Value (0 for an empty cell), INCREFing it.
;; ============================================================================
DEF_FUNC cell_new
    push rbx
    push r12
    mov rbx, rdi               ; contents Value

    mov edi, PyCellObject_size
    lea rsi, [rel cell_type]
    call gc_alloc
    ; rax = new cell (ob_refcnt=1, ob_type set)
    INCREF_V rbx, r12
    mov [rax + PyCellObject.ob_ref], rbx

    ; Track in GC
    push rax
    mov rdi, rax
    call gc_track
    pop rax

.done:
    pop r12
    pop rbx
    leave
    ret
END_FUNC cell_new

;; ============================================================================
;; func_construct(rdi = type, rsi = args, rdx = nargs) -> the new function
;;
;; tp_new: types.FunctionType(code, globals, name=None, argdefs=None,
;; closure=None) -- 3.12's five; kwdefaults arrives in 3.13.  What code that builds a function from a
;; code object reaches for -- copying one with a new closure or new globals,
;; cloudpickle, attrs' and dataclasses' relatives -- and it was "cannot create
;; 'function' instances".  The closure has to match the code's free
;; variables one for one, as CPython requires, or the first LOAD_DEREF reads
;; past the tuple.
;; ============================================================================
FCN_CODE  equ 48            ; the six slots, in parameter order, lowest first
FCN_GLOB  equ 40
FCN_NAME  equ 32
FCN_DEFS  equ 24
FCN_CLOS  equ 16
FCN_SPARE equ 8             ; the binder's sixth slot; 3.13 has kwdefaults
FCN_ARGS  equ 56
FCN_NPOS  equ 64
FCN_FUNC  equ 72
FCN_FRAME equ 80
DEF_FUNC func_construct, FCN_FRAME
    mov [rbp - FCN_ARGS], rsi
    xor eax, eax
    mov [rbp - FCN_CODE], rax
    mov [rbp - FCN_GLOB], rax
    mov [rbp - FCN_NAME], rax
    mov [rbp - FCN_DEFS], rax
    mov [rbp - FCN_CLOS], rax
    mov [rbp - FCN_SPARE], rax
    mov rdi, rsi
    mov rsi, rdx
    lea rdx, [rel fcn_kwnames]
    lea rcx, [rbp - FCN_CODE]
    extern math_bind_kw
    call math_bind_kw
    cmp rax, 5
    ja .fcn_arity
    mov [rbp - FCN_NPOS], rax
    xor ecx, ecx
.fcn_pos:
    cmp rcx, [rbp - FCN_NPOS]
    jae .fcn_bound
    mov rdx, [rbp - FCN_ARGS]
    mov rdx, [rdx + rcx * 8]
    lea rax, [rbp - FCN_CODE]
    mov [rax + rcx * 8], rdx
    inc rcx
    jmp .fcn_pos
.fcn_bound:
    ; code: a code object.  globals: a dict.
    mov rax, [rbp - FCN_CODE]
    test rax, rax
    jz .fcn_arity
    V_TEST_PTR rax, rcx
    ja .fcn_bad_code
    lea rcx, [rel code_type]
    cmp [rax + PyObject.ob_type], rcx
    jne .fcn_bad_code
    mov rax, [rbp - FCN_GLOB]
    test rax, rax
    jz .fcn_arity
    V_TEST_PTR rax, rcx
    ja .fcn_bad_globals
    lea rcx, [rel dict_type]
    cmp [rax + PyObject.ob_type], rcx
    jne .fcn_bad_globals
    ; None is "not given" for the four optional ones.
    lea rcx, [rel none_singleton]
    lea rdx, [rbp - FCN_NAME]           ; name, argdefs, closure
    lea rsi, [rbp - FCN_SPARE]
.fcn_unnone:
    cmp [rdx], rcx
    jne .fcn_unnone_next
    mov qword [rdx], 0
.fcn_unnone_next:
    add rdx, 8
    cmp rdx, rsi
    jb .fcn_unnone
    ; name: a str.  argdefs and closure: tuples.  kwdefaults: a dict.
    mov rax, [rbp - FCN_NAME]
    test rax, rax
    jz .fcn_name_ok
    V_TEST_PTR rax, rcx
    ja .fcn_bad_name
    lea rcx, [rel str_type]
    cmp [rax + PyObject.ob_type], rcx
    jne .fcn_bad_name
.fcn_name_ok:
    mov rax, [rbp - FCN_DEFS]
    test rax, rax
    jz .fcn_defs_ok
    V_TEST_PTR rax, rcx
    ja .fcn_bad_defs
    lea rcx, [rel tuple_type]
    cmp [rax + PyObject.ob_type], rcx
    jne .fcn_bad_defs
.fcn_defs_ok:
    mov rdi, [rbp - FCN_CODE]
    call func_free_count
    mov rcx, [rbp - FCN_CLOS]
    test rcx, rcx
    jnz .fcn_have_clos
    test rax, rax
    jnz .fcn_need_clos
    jmp .fcn_clos_ok
.fcn_have_clos:
    V_TEST_PTR rcx, rdx
    ja .fcn_bad_clos
    lea rdx, [rel tuple_type]
    cmp [rcx + PyObject.ob_type], rdx
    jne .fcn_bad_clos
    cmp rax, [rcx + PyTupleObject.ob_size]
    jne .fcn_clos_len
.fcn_clos_ok:

.fcn_make:
    mov rdi, [rbp - FCN_CODE]
    mov rsi, [rbp - FCN_GLOB]
    call func_new
    mov [rbp - FCN_FUNC], rax
%macro FCN_STORE 2              ; %1 = slot, %2 = PyFuncObject field
    mov rax, [rbp - %1]
    test rax, rax
    jz %%skip
    INCREF rax
    mov rcx, [rbp - FCN_FUNC]
    mov rdi, [rcx + PyFuncObject.%2]
    mov [rcx + PyFuncObject.%2], rax
    test rdi, rdi
    jz %%skip
    call obj_decref
%%skip:
%endmacro
    FCN_STORE FCN_NAME, func_name
    FCN_STORE FCN_DEFS, func_defaults
    FCN_STORE FCN_CLOS, func_closure
    mov rax, [rbp - FCN_FUNC]
    leave
    ret

.fcn_arity:
    RAISE exc_TypeError_type, "function() takes at most 5 arguments"
.fcn_bad_code:
    RAISE exc_TypeError_type, "function() argument 'code' must be code"
.fcn_bad_globals:
    RAISE exc_TypeError_type, "function() argument 'globals' must be dict"
.fcn_bad_name:
    RAISE exc_TypeError_type, "arg 3 (name) must be None or string"
.fcn_bad_defs:
    RAISE exc_TypeError_type, "arg 4 (defaults) must be None or tuple"
.fcn_bad_clos:
    RAISE exc_TypeError_type, "arg 5 (closure) must be tuple"
.fcn_need_clos:
    RAISE exc_TypeError_type, "arg 5 (closure) must be tuple"
.fcn_clos_len:
    RAISE exc_ValueError_type, "closure does not match the code object's free variables"
END_FUNC func_construct

section .rodata
fcn_kw_code:     db "code", 0
fcn_kw_globals:  db "globals", 0
fcn_kw_name:     db "name", 0
fcn_kw_argdefs:  db "argdefs", 0
fcn_kw_closure:  db "closure", 0
align 8
fcn_kwnames: dq fcn_kw_code, fcn_kw_globals, fcn_kw_name, fcn_kw_argdefs
             dq fcn_kw_closure, 0
section .text

;; ============================================================================
;; cell_construct(rdi = type, rsi = args, rdx = nargs) -> the new cell
;;
;; tp_new: types.CellType() is an empty cell and types.CellType(x) holds x,
;; which is how code builds a closure by hand for types.FunctionType.
;; ============================================================================
DEF_FUNC cell_construct
    xor edi, edi
    test rdx, rdx
    jz .cc_make
    cmp rdx, 1
    jne .cc_arity
    mov rdi, [rsi]
.cc_make:
    call cell_new
    leave
    ret
.cc_arity:
    RAISE exc_TypeError_type, "cell expected at most 1 argument"
END_FUNC cell_construct



;; ============================================================================
;; cell_dealloc(PyCellObject *self)
;; ============================================================================
DEF_FUNC cell_dealloc, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi

    mov rdi, [rbx + PyCellObject.ob_ref]
    DECREF_V rdi, rsi

.free:
    mov rdi, rbx
    call gc_dealloc

    pop rbx
    leave
    ret
END_FUNC cell_dealloc

;; ============================================================================
;; cell_repr(PyCellObject *self) -> PyStrObject*
;; ============================================================================
DEF_FUNC_BARE cell_repr
    lea rdi, [rel cell_repr_str]
    jmp str_from_cstr
END_FUNC cell_repr

;; ============================================================================
;; Data
;; ============================================================================
section .data

cell_name_str: db "cell", 0
cell_repr_str: db "<cell>", 0

align 8
section .text

;; ============================================================================
;; cell_getattr(rdi = a cell, rsi = the name) -> rax = Value, owned, or 0
;;
;; `cell_contents`, the one attribute a cell has beyond object's: the value
;; the closure sees.  attrs and jsonschema read it at import time, and attrs
;; writes it too -- that is how it points a method's __class__ cell at the
;; class it rebuilt.  An empty cell is a ValueError, as in CPython.  Any other
;; name answers 0 and the generic lookup takes over.
;; ============================================================================
DEF_FUNC cell_getattr
    push rdi
    sub rsp, 8
    lea rdi, [rsi + PyStrObject.data]
    lea rsi, [rel cell_contents_cstr]
    call ap_strcmp
    add rsp, 8
    pop rdi
    test eax, eax
    jnz .cga_other
    mov rax, [rdi + PyCellObject.ob_ref]
    test rax, rax
    jz .cga_empty
    INCREF_V rax, rcx
    leave
    ret
.cga_empty:
    RAISE exc_ValueError_type, "Cell is empty"
.cga_other:
    xor eax, eax
    leave
    ret
END_FUNC cell_getattr

;; ============================================================================
;; cell_setattr(rdi = a cell, rsi = the name, rdx = the Value, 0 to delete)
;;   -> nothing
;;
;; `cell_contents` takes any value, and a delete empties the cell.  Anything
;; else is CPython's AttributeError for an object with no such attribute.
;; ============================================================================
CSA_CELL  equ 8
CSA_NAME  equ 16
CSA_VAL   equ 24
CSA_FRAME equ 32
DEF_FUNC cell_setattr, CSA_FRAME
    mov [rbp - CSA_CELL], rdi
    mov [rbp - CSA_NAME], rsi
    mov [rbp - CSA_VAL], rdx
    lea rdi, [rsi + PyStrObject.data]
    lea rsi, [rel cell_contents_cstr]
    call ap_strcmp
    test eax, eax
    jnz .csa_other
    ; Store first, release second: old and new may be the same object.
    mov rax, [rbp - CSA_VAL]
    INCREF_V rax, rcx
    mov rcx, [rbp - CSA_CELL]
    mov rdi, [rcx + PyCellObject.ob_ref]
    mov [rcx + PyCellObject.ob_ref], rax
    XDECREF_V rdi, rcx
    leave
    ret
.csa_other:
    mov rdi, [rbp - CSA_CELL]
    mov rsi, [rbp - CSA_NAME]
    mov edx, 1
    extern raise_no_attribute
    call raise_no_attribute
END_FUNC cell_setattr

section .rodata
cell_contents_cstr: db "cell_contents", 0
section .data

align 8
global cell_type
cell_type:
    dq 1                      ; ob_refcnt (immortal)
    dq type_type              ; ob_type
    dq cell_name_str          ; tp_name
    dq PyCellObject_size      ; tp_basicsize
    dq cell_dealloc           ; tp_dealloc
    dq cell_repr              ; tp_repr
    dq cell_repr              ; tp_str
    dq 0                      ; tp_hash
    dq 0                      ; tp_call
    dq cell_getattr           ; tp_getattr
    dq cell_setattr           ; tp_setattr
    dq 0                      ; tp_richcompare
    dq 0                      ; tp_iter
    dq 0                      ; tp_iternext
    dq 0                      ; tp_init
    dq cell_construct         ; tp_new
    dq 0                      ; tp_as_number
    dq 0                      ; tp_as_sequence
    dq 0                      ; tp_as_mapping
    dq 0                      ; tp_base
    dq 0                      ; tp_dict
    dq 0                      ; tp_mro
    dq TYPE_FLAG_HAVE_GC                      ; tp_flags
    dq 0                      ; tp_bases
    dq cell_traverse                        ; tp_traverse
    dq cell_clear                        ; tp_clear
    dq 0       ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

section .text

;; ============================================================================
;; GC traverse and clear.  These lived in gc.asm, which left the collector
;; holding the reference graph of every type in the system; a type's own
;; file is the only place that knows which of its fields are owned.
;; ============================================================================

;; ============================================================================
;; ---- func_traverse / func_clear ----
;; ============================================================================
DEF_FUNC func_traverse, 8        ; rsp 16-aligned at the call the macros below expand to
    push rbx
    mov rbx, rdi

    mov rdi, [rbx + PyFuncObject.func_code]
    VISIT_PTR rdi
    mov rdi, [rbx + PyFuncObject.func_globals]
    VISIT_PTR rdi
    mov rdi, [rbx + PyFuncObject.func_name]
    VISIT_PTR rdi
    mov rdi, [rbx + PyFuncObject.func_defaults]
    VISIT_PTR rdi
    mov rdi, [rbx + PyFuncObject.func_closure]
    VISIT_PTR rdi
    mov rdi, [rbx + PyFuncObject.func_kwdefaults]
    VISIT_PTR rdi
    mov rdi, [rbx + PyFuncObject.func_dict]
    VISIT_PTR rdi
    mov rax, [rbx + PyFuncObject.func_qualname]
    VISIT_V rax, rcx
    mov rax, [rbx + PyFuncObject.func_doc]
    VISIT_V rax, rcx
    mov rdi, [rbx + PyFuncObject.func_annotations]
    VISIT_PTR rdi
    mov rax, [rbx + PyFuncObject.func_module]
    VISIT_V rax, rcx

    pop rbx
    leave
    ret
END_FUNC func_traverse

DEF_FUNC func_clear, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi

    ; NULL out closure, defaults, kwdefaults, func_dict — XDECREF each
    mov rdi, [rbx + PyFuncObject.func_closure]
    mov qword [rbx + PyFuncObject.func_closure], 0
    test rdi, rdi
    jz .no_clos
    call obj_decref
.no_clos:
    mov rdi, [rbx + PyFuncObject.func_defaults]
    mov qword [rbx + PyFuncObject.func_defaults], 0
    test rdi, rdi
    jz .no_defs
    call obj_decref
.no_defs:
    mov rdi, [rbx + PyFuncObject.func_kwdefaults]
    mov qword [rbx + PyFuncObject.func_kwdefaults], 0
    test rdi, rdi
    jz .no_kwd
    call obj_decref
.no_kwd:
    mov rdi, [rbx + PyFuncObject.func_dict]
    mov qword [rbx + PyFuncObject.func_dict], 0
    test rdi, rdi
    jz .no_fdict
    call obj_decref
.no_fdict:
    mov rdi, [rbx + PyFuncObject.func_qualname]
    mov qword [rbx + PyFuncObject.func_qualname], 0
    test rdi, rdi
    jz .no_fqual
    DECREF_V rdi, rcx
.no_fqual:
    mov rdi, [rbx + PyFuncObject.func_doc]
    mov qword [rbx + PyFuncObject.func_doc], 0
    test rdi, rdi
    jz .no_fdoc
    DECREF_V rdi, rcx
.no_fdoc:
    mov rdi, [rbx + PyFuncObject.func_annotations]
    mov qword [rbx + PyFuncObject.func_annotations], 0
    test rdi, rdi
    jz .no_fannos
    call obj_decref
.no_fannos:
    mov rdi, [rbx + PyFuncObject.func_module]
    mov qword [rbx + PyFuncObject.func_module], 0
    test rdi, rdi
    jz .no_fmodule
    DECREF_V rdi, rcx
.no_fmodule:

    pop rbx
    leave
    ret
END_FUNC func_clear

;; ============================================================================
;; ---- cell_traverse / cell_clear ----
;; ============================================================================
DEF_FUNC cell_traverse, 8        ; rsp 16-aligned at the call the macros below expand to
    push rbx
    mov rbx, rdi

    mov rdi, [rbx + PyCellObject.ob_ref]
    VISIT_V rdi, rsi

    pop rbx
    leave
    ret
END_FUNC cell_traverse

DEF_FUNC cell_clear, 8        ; rsp 16-aligned at the call the macros below expand to
    push rbx
    mov rbx, rdi

    mov rdi, [rbx + PyCellObject.ob_ref]
    mov qword [rbx + PyCellObject.ob_ref], 0
    DECREF_V rdi, rsi

    pop rbx
    leave
    ret
END_FUNC cell_clear
