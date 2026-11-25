; methodinit.inc - the macros that put a method into a type's tp_dict.
;
; They lived in src/methods/init.asm, which is the file that uses most of them.
; init.asm reached the 100k cap for a hand-written file, so the numeric types
; moved out to init_num.asm -- and a second file using the macros is what made
; them a shared header rather than a local convenience.
;
; Every one of them reads the dict from rbx, except the _D forms, which take a
; frame slot: the shared method bodies keep theirs there.

%ifndef METHODINIT_INC
%define METHODINIT_INC

; A name a type's own tp_getattr already answers, published as a read-only
; getset descriptor so the type's dict holds it too.  The dict is in rbx, as
; ADD_FN wants it.
%macro TYPE_GETATTR 2           ; %1 = the name symbol, %2 = the getattr fn
    mov rdi, rbx
    lea rsi, [rel %1]
    lea rdx, [rel %2]
    call dict_add_getattr
%endmacro

%macro MV_GETATTR 1
    TYPE_GETATTR %1, memoryview_getattr
%endmacro

%macro PROP_GETATTR 1
    TYPE_GETATTR %1, property_getattr
%endmacro

%macro DESCR_GETATTR 1
    TYPE_GETATTR %1, descr_func_attr
%endmacro

%macro ADD_FN 2
    mov rdi, rbx
    lea rsi, [rel %1]
    lea rdx, [rel %2]
    call dict_add_builtin_func
%endmacro

;; ADD_FN_D slot, name, func -- the same, for the few blocks whose dict is in a
;; frame slot rather than in rbx.
%macro ADD_FN_D 3
    mov rdi, [rbp - %1]
    lea rsi, [rel %2]
    lea rdx, [rel %3]
    call dict_add_builtin_func
%endmacro

; The same with an explicit dict, for the shared blocks that keep theirs in
; a frame slot rather than in rbx.
%macro ADD_FN_DN 5
    mov rdi, [rbp - %1]
    lea rsi, [rel %2]
    lea rdx, [rel %3]
    mov rcx, %4
    mov r8, %5
    call add_method_to_dict_checked
%endmacro

%macro ADD_FN_N 4
    mov rdi, rbx
    lea rsi, [rel %1]
    lea rdx, [rel %2]
    mov rcx, %3
    mov r8, %4
    call add_method_to_dict_checked
%endmacro

%macro ADD_CLASSMETHOD 2
    ADD_CLASSMETHOD_N %1, %2, 0, -1
%endmacro

%macro ADD_CLASSMETHOD_N 4
    lea rdi, [rel %2]
    lea rsi, [rel %1]
    mov rdx, %3
    mov rcx, %4
    call builtin_func_new_checked
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
    lea rdi, [rel %1]
    call str_intern_cstr
    push rax
    mov rdi, rbx
    mov rsi, rax
    mov rdx, [rsp + 8]
    call dict_set_str
    pop rdi
    call obj_decref
    pop rdi
    call obj_decref
%endmacro

%macro GEN_GETSET 2             ; %1 = the name string, %2 = the getter
    mov rdi, rbx
    lea rsi, [rel %1]
    extern %2
    lea rdx, [rel %2]
    xor ecx, ecx
    call dict_add_getset
%endmacro

%endif ; METHODINIT_INC
