; objerr.asm - the arity and receiver error messages.
;
; Split out of object.asm, which reached the 100k cap that src/compiler/lint.py
; enforces.  The seam is the one object.asm already had: these six build a
; message into a stack buffer and hand it to raise_exception, and none of them
; returns.  They share nothing with the object protocol above them but the two
; append helpers, and every one of them exists for the same reason -- CPython
; reports the count and the receiver it actually got, and this tree used to
; report the rule and leave the caller to guess what it had passed.
;
; The remaining raise_* helpers stay in object.asm: they are interleaved with
; value_type, dunder_require_self and the msg_append_* primitives they are
; built on, and cutting between them would mean moving those too.

%include "macros.inc"
%include "object.inc"

; --- the message primitives, which stay in object.asm ---
extern msg_append_i64
extern rbt_append_cstr
extern rbt_typename

; --- what the messages describe ---
extern value_type
extern ap_strcmp

; --- raising ---
extern raise_exception
extern exc_TypeError_type
extern exc_ValueError_type

section .text


;; ============================================================================
;; raise_type_error_counted(rdi = the text before the number, rsi = the count,
;;                          rdx = the text after it, or 0)
;;   -> does not return: the composed message is raised as a TypeError
;;
;; "str() takes at most 3 arguments (4 given)".  CPython reports the count in
;; every arity message and this tree reported it in almost none, so a caller
;; was told the rule but not what it had actually passed.
;; ============================================================================
RTC_N     equ 8
RTC_TAIL  equ 16
RTC_BUF   equ 192
RTC_FRAME equ 192           ; + 0 pushes = 192, 16-aligned
global raise_type_error_counted
DEF_FUNC raise_type_error_counted, RTC_FRAME
    mov [rbp - RTC_N], rsi
    mov [rbp - RTC_TAIL], rdx
    mov rsi, rdi
    lea rdi, [rbp - RTC_BUF]
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - RTC_N]
    call msg_append_i64
    cmp qword [rbp - RTC_TAIL], 0
    je .rtc_raise
    mov rdi, rax
    mov rsi, [rbp - RTC_TAIL]
    call rbt_append_cstr
.rtc_raise:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rbp - RTC_BUF]
    call raise_exception
END_FUNC raise_type_error_counted

;; ============================================================================
;; raise_value_error_counted(rdi = the text before the number, rsi = the
;;                           count, rdx = the text after it, or 0)
;;   -> does not return: the composed message is raised as a ValueError
;;
;; The same composition as raise_type_error_counted, for the messages that
;; are ValueErrors: "Item 0 of second argument (exceptions) is not an
;; exception".
;; ============================================================================
global raise_value_error_counted
DEF_FUNC raise_value_error_counted, RTC_FRAME
    mov [rbp - RTC_N], rsi
    mov [rbp - RTC_TAIL], rdx
    mov rsi, rdi
    lea rdi, [rbp - RTC_BUF]
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - RTC_N]
    call msg_append_i64
    cmp qword [rbp - RTC_TAIL], 0
    je .rvc_raise
    mov rdi, rax
    mov rsi, [rbp - RTC_TAIL]
    call rbt_append_cstr
.rvc_raise:
    extern exc_ValueError_type
    lea rdi, [rel exc_ValueError_type]
    lea rsi, [rbp - RTC_BUF]
    call raise_exception
END_FUNC raise_value_error_counted


;; ============================================================================
;; raise_typed_message(rdi = a Value, rsi = the text before the type name,
;;                     rdx = the text after it, or 0)
;;   -> does not return: a TypeError naming the argument's type
;;
;; The shape CPython uses for a refusal that is about WHAT it was handed:
;; "argument of type 'ValueError' is not iterable", "__bytes__ returned
;; non-bytes (type int)".  Three messages in this tree said the same thing
;; with the type left out, each from a different file, because naming a type
;; in a message meant building a buffer and none of them wanted to.
;; ============================================================================
RTM_VAL    equ 8
RTM_SUFFIX equ 16
RTM_BUF    equ 224
RTM_FRAME  equ 224          ; + 0 pushes = 224, 16-aligned
global raise_typed_message
DEF_FUNC raise_typed_message, RTM_FRAME
    mov [rbp - RTM_VAL], rdi
    mov [rbp - RTM_SUFFIX], rdx
    lea rdi, [rbp - RTM_BUF]
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - RTM_VAL]
    extern rbt_typename
    call rbt_typename
    mov rsi, [rbp - RTM_SUFFIX]
    test rsi, rsi
    jz .rtm_raise
    mov rdi, rax
    call rbt_append_cstr
.rtm_raise:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rbp - RTM_BUF]
    call raise_exception
    ud2
END_FUNC raise_typed_message

;; ============================================================================
;; raise_final_base(rdi = the type's name, as a C string)
;;   -> does not return: the message is raised as a TypeError
;;
;; "type 'bool' is not an acceptable base type", for a type CPython gives no
;; Py_TPFLAGS_BASETYPE.
;; ============================================================================
RFB_BUF   equ 176
RFB_FRAME equ 176           ; + 0 pushes = 176, 16-aligned
global raise_final_base
DEF_FUNC raise_final_base, RFB_FRAME
    mov rdx, rdi
    lea rdi, [rbp - RFB_BUF]
    CSTRING rsi, "type '"
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, rdx
    call rbt_append_cstr
    mov rdi, rax
    CSTRING rsi, "' is not an acceptable base type"
    call rbt_append_cstr
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rbp - RFB_BUF]
    call raise_exception
END_FUNC raise_final_base

;; ============================================================================
;; raise_descriptor_receiver(rdi = the PyBuiltinObject, rsi = the receiver
;;                           Value)
;;   -> does not return: the message is raised as a TypeError
;;
;; CPython has two wordings here, and which one you get says what kind of
;; descriptor you reached:
;;   descriptor 'append' for 'list' objects doesn't apply to a 'tuple' object
;;   descriptor '__neg__' requires a 'int' object but received a 'float'
;; The first is a method descriptor, the second a slot wrapper.  func_kind
;; already records which, for the repr; this is the second reader of it.
;; ============================================================================
RDR_DESC  equ 8
RDR_RECV  equ 16
RDR_BUF   equ 240
RDR_FRAME equ 240           ; + 0 pushes = 240, 16-aligned
global raise_descriptor_receiver
DEF_FUNC raise_descriptor_receiver, RDR_FRAME
    mov [rbp - RDR_DESC], rdi
    mov [rbp - RDR_RECV], rsi
    lea rdi, [rbp - RDR_BUF]
    CSTRING rsi, "descriptor '"
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - RDR_DESC]
    mov rsi, [rsi + PyBuiltinObject.func_name]
    lea rsi, [rsi + PyStrObject.data]
    call rbt_append_cstr
    mov rdi, rax

    mov rcx, [rbp - RDR_DESC]
    cmp qword [rcx + PyBuiltinObject.func_kind], BUILTIN_KIND_WRAPPER
    je .rdr_wrapper

    CSTRING rsi, "' for '"
    call rbt_append_cstr
    mov rdi, rax
    call .rdr_owner_name
    mov rdi, rax
    CSTRING rsi, "' objects doesn't apply to a '"
    call rbt_append_cstr
    mov rdi, rax
    call .rdr_recv_name
    mov rdi, rax
    CSTRING rsi, "' object"
    call rbt_append_cstr
    jmp .rdr_raise

.rdr_wrapper:
    CSTRING rsi, "' requires a '"
    call rbt_append_cstr
    mov rdi, rax
    call .rdr_owner_name
    mov rdi, rax
    CSTRING rsi, "' object but received a '"
    call rbt_append_cstr
    mov rdi, rax
    call .rdr_recv_name
    mov rdi, rax
    CSTRING rsi, "'"
    call rbt_append_cstr

.rdr_raise:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rbp - RDR_BUF]
    call raise_exception

;; The two names, appended at the cursor in rdi.
.rdr_owner_name:
    mov rcx, [rbp - RDR_DESC]
    mov rcx, [rcx + PyBuiltinObject.func_owner]
    mov rsi, [rcx + PyTypeObject.tp_name]
    jmp rbt_append_cstr
.rdr_recv_name:
    push rdi
    mov rdi, [rbp - RDR_RECV]
    call value_type
    test rax, rax
    jz .rdr_recv_unknown
    mov rsi, [rax + PyTypeObject.tp_name]
    jmp .rdr_recv_go
.rdr_recv_unknown:
    CSTRING rsi, "object"
.rdr_recv_go:
    pop rdi
    jmp rbt_append_cstr
END_FUNC raise_descriptor_receiver

;; ============================================================================
;; raise_missing_receiver(rdi = the PyBuiltinObject)
;;   -> does not return: the message is raised as a TypeError
;;
;; A method descriptor or a slot wrapper reached UNBOUND and called with no
;; arguments at all.  There is no receiver to check, so raise_descriptor_
;; receiver above cannot word it; CPython has a separate pair for this, and
;; the same split by kind:
;;   unbound method generator.close() needs an argument
;;   descriptor '__get__' of 'classmethod' object needs an argument
;;
;; The shape reaching here is `type(g()).close(*())` -- an unbound method and
;; an empty argument sequence.  It cannot arrive through a bound method,
;; which always prepends its receiver, which is why tests/arity_probe.sh
;; could not see it: the probe calls every method through an instance, so
;; nargs is never 0 there.
;; ============================================================================
RMR_DESC  equ 8
RMR_BUF   equ 240
RMR_FRAME equ 240           ; + 0 pushes = 240, 16-aligned
global raise_missing_receiver
DEF_FUNC raise_missing_receiver, RMR_FRAME
    mov [rbp - RMR_DESC], rdi
    lea rdi, [rbp - RMR_BUF]
    mov rcx, [rbp - RMR_DESC]
    cmp qword [rcx + PyBuiltinObject.func_kind], BUILTIN_KIND_WRAPPER
    je .rmr_wrapper

    ; unbound method <owner>.<name>() needs an argument
    CSTRING rsi, "unbound method "
    call rbt_append_cstr
    mov rdi, rax
    call .rmr_owner_name
    mov rdi, rax
    CSTRING rsi, "."
    call rbt_append_cstr
    mov rdi, rax
    call .rmr_func_name
    mov rdi, rax
    CSTRING rsi, "() needs an argument"
    call rbt_append_cstr
    jmp .rmr_raise

.rmr_wrapper:
    ; descriptor '<name>' of '<owner>' object needs an argument
    CSTRING rsi, "descriptor '"
    call rbt_append_cstr
    mov rdi, rax
    call .rmr_func_name
    mov rdi, rax
    CSTRING rsi, "' of '"
    call rbt_append_cstr
    mov rdi, rax
    call .rmr_owner_name
    mov rdi, rax
    CSTRING rsi, "' object needs an argument"
    call rbt_append_cstr

.rmr_raise:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rbp - RMR_BUF]
    call raise_exception

.rmr_owner_name:
    mov rcx, [rbp - RMR_DESC]
    mov rcx, [rcx + PyBuiltinObject.func_owner]
    mov rsi, [rcx + PyTypeObject.tp_name]
    jmp rbt_append_cstr
.rmr_func_name:
    mov rcx, [rbp - RMR_DESC]
    mov rsi, [rcx + PyBuiltinObject.func_name]
    lea rsi, [rsi + PyStrObject.data]
    jmp rbt_append_cstr
END_FUNC raise_missing_receiver

;; ============================================================================
;; raise_wrapper_arity(rdi = the number of arguments wanted, not counting
;;                     self; rsi = the number given, likewise)
;;   -> does not return: the message is raised as a TypeError
;;
;; "expected 0 arguments, got 1" -- CPython's wording for a slot wrapper.
;; Every one of these said "expected exactly one argument", which is neither
;; the count nor, for the nullary ones, even the right number.
;; ============================================================================
RWA_WANT  equ 8
RWA_GOT   equ 16
RWA_BUF   equ 192
RWA_FRAME equ 192           ; + 0 pushes = 192, 16-aligned
global raise_wrapper_arity
DEF_FUNC raise_wrapper_arity, RWA_FRAME
    mov [rbp - RWA_WANT], rdi
    mov [rbp - RWA_GOT], rsi
    lea rdi, [rbp - RWA_BUF]
    ; CPython has two helpers here and they differ by one space.  Most
    ; wrappers use check_num_args -- "expected 1 argument, got 0" -- while
    ; the __setitem__/__delitem__ shape goes through PyArg_UnpackTuple with
    ; an EMPTY function name, and that format leaves the gap where the name
    ; would have been.
    test edx, edx
    jz .rwa_no_gap
    CSTRING rsi, " expected "
    jmp .rwa_opened
.rwa_no_gap:
    CSTRING rsi, "expected "
.rwa_opened:
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - RWA_WANT]
    call msg_append_i64
    mov rdi, rax
    cmp qword [rbp - RWA_WANT], 1
    je .rwa_singular
    CSTRING rsi, " arguments, got "
    jmp .rwa_join
.rwa_singular:
    CSTRING rsi, " argument, got "
.rwa_join:
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - RWA_GOT]
    call msg_append_i64
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rbp - RWA_BUF]
    call raise_exception
END_FUNC raise_wrapper_arity

;; ============================================================================
;; raise_builtin_arity(rdi = the PyBuiltinObject, rsi = the count given,
;;                     rdx = the count wanted, ecx = 0 too few / 1 too many)
;;   -- neither count includes self
;;   -> does not return: the message is raised as a TypeError
;;
;; CPython's shapes, which differ by whether the method takes a fixed number:
;;   list.append() takes exactly one argument (2 given)
;;   str.upper() takes no arguments (1 given)
;;   hex() takes at most 2 arguments (3 given)
;;   endswith() takes at least 1 argument (0 given)
;;   expected 0 arguments, got 1            <- a slot wrapper
;;
;; A method with a range says "at most" when it was given too many and "at
;; least" when too few; reading the direction off min != max alone reported
;; "at most 1 arguments (0 given)", which is both wrong and self-contradictory.
;; ============================================================================
RBA_DESC  equ 8
RBA_GOT   equ 16
RBA_WANT  equ 24
RBA_OVER  equ 32            ; 1 = too many, 0 = too few
RBA_BUF   equ 240
RBA_FRAME equ 240           ; + 0 pushes = 240, 16-aligned
global raise_builtin_arity
DEF_FUNC raise_builtin_arity, RBA_FRAME
    mov [rbp - RBA_DESC], rdi
    mov [rbp - RBA_GOT], rsi
    mov [rbp - RBA_WANT], rdx
    mov [rbp - RBA_OVER], rcx

    ; A slot wrapper has its own wording, and never names itself.
    cmp qword [rdi + PyBuiltinObject.func_kind], BUILTIN_KIND_WRAPPER
    jne .rba_method
    ; ...except that the two-argument item wrappers go through CPython's
    ; OTHER helper, whose format leaves a gap for the name it was given
    ; empty.  __setitem__ and __delitem__ are the pair.
    mov rsi, [rdi + PyBuiltinObject.func_name]
    lea rdi, [rsi + PyStrObject.data]
    CSTRING rsi, "__setitem__"
    push rdx
    call ap_strcmp
    pop rdx
    test eax, eax
    jz .rba_wrapper_gap
    mov rcx, [rbp - RBA_DESC]
    mov rsi, [rcx + PyBuiltinObject.func_name]
    lea rdi, [rsi + PyStrObject.data]
    CSTRING rsi, "__delitem__"
    push rdx
    call ap_strcmp
    pop rdx
    test eax, eax
    jz .rba_wrapper_gap
    xor edx, edx
    jmp .rba_wrapper
.rba_wrapper_gap:
    mov edx, 1
.rba_wrapper:
    mov rdi, [rbp - RBA_WANT]
    mov rsi, [rbp - RBA_GOT]
    jmp raise_wrapper_arity

.rba_method:
    lea rdi, [rbp - RBA_BUF]
    mov rcx, [rbp - RBA_DESC]
    cmp qword [rcx + PyBuiltinObject.func_owner], 0
    je .rba_bare_name
    mov rsi, [rcx + PyBuiltinObject.func_owner]
    mov rsi, [rsi + PyTypeObject.tp_name]
    call rbt_append_cstr
    mov rdi, rax
    CSTRING rsi, "."
    call rbt_append_cstr
    mov rdi, rax
.rba_bare_name:
    mov rcx, [rbp - RBA_DESC]
    mov rsi, [rcx + PyBuiltinObject.func_name]
    lea rsi, [rsi + PyStrObject.data]
    call rbt_append_cstr
    mov rdi, rax

    ; A fixed arity names the number; a range says "at most".
    mov rcx, [rbp - RBA_DESC]
    mov rax, [rcx + PyBuiltinObject.min_args]
    cmp rax, [rcx + PyBuiltinObject.max_args]
    jne .rba_range
    cmp qword [rbp - RBA_WANT], 0
    je .rba_none
    cmp qword [rbp - RBA_WANT], 1
    je .rba_one
    CSTRING rsi, "() takes exactly "
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - RBA_WANT]
    call msg_append_i64
    mov rdi, rax
    CSTRING rsi, " arguments ("
    jmp .rba_tail
.rba_one:
    CSTRING rsi, "() takes exactly one argument ("
    jmp .rba_tail
.rba_none:
    CSTRING rsi, "() takes no arguments ("
    jmp .rba_tail
.rba_range:
    cmp qword [rbp - RBA_OVER], 0
    jne .rba_range_over
    CSTRING rsi, "() takes at least "
    jmp .rba_range_count
.rba_range_over:
    CSTRING rsi, "() takes at most "
.rba_range_count:
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - RBA_WANT]
    call msg_append_i64
    mov rdi, rax
    CSTRING rsi, " arguments ("
    cmp qword [rbp - RBA_WANT], 1
    jne .rba_tail
    CSTRING rsi, " argument ("
.rba_tail:
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - RBA_GOT]
    call msg_append_i64
    mov rdi, rax
    CSTRING rsi, " given)"
    call rbt_append_cstr
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rbp - RBA_BUF]
    call raise_exception
END_FUNC raise_builtin_arity

;; ============================================================================
;; raise_new_bad_class(rdi = the type whose __new__ this is, rsi = the class
;;                     argument as a Value, edx = 0 no argument / 1 not a type
;;                     / 2 not a subtype)
;;   -> does not return: the composed message is raised as a TypeError
;;
;; The three ways `T.__new__(cls, ...)` can be called wrongly, worded as
;; CPython words them:
;;   list.__new__(): not enough arguments
;;   list.__new__(X): X is not a type object (int)
;;   list.__new__(dict): dict is not a subtype of list
;;   int.__new__(bool) is not safe, use bool.__new__()
;;
;; The first name is the type the __new__ was found on, not the argument's:
;; that is what says which constructor was reached, and it is the whole point
;; of the message.  `X` is CPython's literal placeholder, not the argument.
;; ============================================================================
RNB_OWNER equ 8
RNB_ARG   equ 16
RNB_WHY   equ 24
RNB_BUF   equ 400
RNB_FRAME equ 400           ; + 0 pushes = 400, 16-aligned
global raise_new_bad_class
DEF_FUNC raise_new_bad_class, RNB_FRAME
    mov [rbp - RNB_OWNER], rdi
    mov [rbp - RNB_ARG], rsi
    mov [rbp - RNB_WHY], rdx

    lea rdi, [rbp - RNB_BUF]
    call .rnb_owner_name
    mov rdi, rax

    cmp qword [rbp - RNB_WHY], 0
    je .rnb_no_arg
    cmp qword [rbp - RNB_WHY], 1
    je .rnb_not_type
    cmp qword [rbp - RNB_WHY], 3
    je .rnb_not_safe

    ; "T.__new__(cls): cls is not a subtype of T"
    CSTRING rsi, ".__new__("
    call rbt_append_cstr
    mov rdi, rax
    call .rnb_arg_name
    mov rdi, rax
    CSTRING rsi, "): "
    call rbt_append_cstr
    mov rdi, rax
    call .rnb_arg_name
    mov rdi, rax
    CSTRING rsi, " is not a subtype of "
    call rbt_append_cstr
    mov rdi, rax
    call .rnb_owner_name
    jmp .rnb_raise

.rnb_no_arg:
    CSTRING rsi, ".__new__(): not enough arguments"
    call rbt_append_cstr
    jmp .rnb_raise

.rnb_not_safe:
    ; "T.__new__(cls) is not safe, use cls.__new__()" -- cls is a subtype, but
    ; the constructor that would actually run for it is not T's.
    CSTRING rsi, ".__new__("
    call rbt_append_cstr
    mov rdi, rax
    call .rnb_arg_name
    mov rdi, rax
    CSTRING rsi, ") is not safe, use "
    call rbt_append_cstr
    mov rdi, rax
    call .rnb_arg_name
    mov rdi, rax
    CSTRING rsi, ".__new__()"
    call rbt_append_cstr
    jmp .rnb_raise

.rnb_not_type:
    CSTRING rsi, ".__new__(X): X is not a type object ("
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - RNB_ARG]
    call rbt_typename
    mov rdi, rax
    CSTRING rsi, ")"
    call rbt_append_cstr

.rnb_raise:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rbp - RNB_BUF]
    call raise_exception

;; The two names, appended at the cursor in rdi.  The argument is a class here
;; -- reason 2 is the only caller -- so its own tp_name is what to print, not
;; the metatype's, which is what rbt_typename would give.
.rnb_owner_name:
    mov rcx, [rbp - RNB_OWNER]
    mov rsi, [rcx + PyTypeObject.tp_name]
    jmp rbt_append_cstr
.rnb_arg_name:
    mov rcx, [rbp - RNB_ARG]
    mov rsi, [rcx + PyTypeObject.tp_name]
    jmp rbt_append_cstr
END_FUNC raise_new_bad_class

;; ============================================================================
;; obj_getattr_str_opt(rdi = an object, rsi = an attribute name as a C string)
;;   -> rax = the attribute when it is a str, a NEW reference; else 0
;;
;; getattr with no exception and no surprises: anything that is not a str is
;; treated as absent, which is what CPython's fallback amounts to.  Shared
;; with method_repr, which asks the same question of a method's im_func --
;; CPython's method_repr asks for __qualname__ and then __name__ exactly this
;; way, and falls back to "?".
;; ============================================================================
RAC_STR   equ 8
RAC_VAL   equ 16
RAC_FRAME equ 24            ; + 1 push = 32, 16-aligned
extern obj_getattr_opt
extern str_from_cstr_heap
extern obj_decref
extern str_type
extern obj_dealloc
global obj_getattr_str_opt
DEF_FUNC_LOCAL obj_getattr_str_opt, RAC_FRAME
    push rbx
    mov rbx, rdi
    mov rdi, rsi
    call str_from_cstr_heap
    mov [rbp - RAC_STR], rax
    mov rdi, rbx
    mov rsi, rax
    call obj_getattr_opt
    mov [rbp - RAC_VAL], rax
    mov rdi, [rbp - RAC_STR]
    call obj_decref
    mov rax, [rbp - RAC_VAL]
    test rax, rax
    jz .rac_none
    V_TEST_PTR rax, rcx
    ja .rac_release
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    jne .rac_release
    pop rbx
    leave
    ret
.rac_release:
    mov rdi, rax
    DECREF_V rdi, rcx
.rac_none:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC obj_getattr_str_opt

;; ============================================================================
;; raise_callable_arg(rdi = the callable, rsi = a C string to append,
;;                    rdx = the text between them, rcx = a suffix or 0)
;;   -> does not return: the composed message is raised as a TypeError
;;
;; "__main__.f() argument after ** must be a mapping, not int", and
;; "__main__.f() got multiple values for keyword argument 'a'".  CPython names
;; the callable in every refusal CALL_FUNCTION_EX makes, through
;; _PyObject_FunctionStr: the qualified name, prefixed by the module unless
;; that is builtins or missing, and then "()".  A callable that answers
;; neither name is printed as its type, which is CPython's own fallback.
;;
;; Every attribute is APPENDED before it is released.  Reading a str's data
;; after giving its reference back is the shape half of today's bugs had.
;; ============================================================================
RCA_FUNC  equ 8
RCA_ARG   equ 16
RCA_MID   equ 24
RCA_CUR   equ 32
RCA_HELD  equ 40
RCA_SUF   equ 48            ; a trailing quote, or 0
RCA_BUF   equ 456
RCA_FRAME equ 464           ; + 0 pushes = 464, 16-aligned
global raise_callable_arg
DEF_FUNC raise_callable_arg, RCA_FRAME
    mov [rbp - RCA_FUNC], rdi
    mov [rbp - RCA_ARG], rsi
    mov [rbp - RCA_MID], rdx
    mov [rbp - RCA_SUF], rcx
    lea rax, [rbp - RCA_BUF]
    mov [rbp - RCA_CUR], rax

    mov rdi, [rbp - RCA_FUNC]
    CSTRING rsi, "__module__"
    call obj_getattr_str_opt
    test rax, rax
    jz .rca_no_module
    mov [rbp - RCA_HELD], rax
    lea rdi, [rax + PyStrObject.data]
    CSTRING rsi, "builtins"
    call ap_strcmp
    test eax, eax
    jz .rca_drop_module
    mov rdi, [rbp - RCA_CUR]
    mov rsi, [rbp - RCA_HELD]
    lea rsi, [rsi + PyStrObject.data]
    call rbt_append_cstr
    mov rdi, rax
    CSTRING rsi, "."
    call rbt_append_cstr
    mov [rbp - RCA_CUR], rax
.rca_drop_module:
    mov rdi, [rbp - RCA_HELD]
    call obj_decref
.rca_no_module:

    mov rdi, [rbp - RCA_FUNC]
    CSTRING rsi, "__qualname__"
    call obj_getattr_str_opt
    test rax, rax
    jnz .rca_have_name
    mov rdi, [rbp - RCA_FUNC]
    CSTRING rsi, "__name__"
    call obj_getattr_str_opt
    test rax, rax
    jz .rca_use_type
.rca_have_name:
    mov [rbp - RCA_HELD], rax
    mov rdi, [rbp - RCA_CUR]
    mov rsi, rax
    lea rsi, [rsi + PyStrObject.data]
    call rbt_append_cstr
    mov [rbp - RCA_CUR], rax
    mov rdi, [rbp - RCA_HELD]
    call obj_decref
    jmp .rca_tail

.rca_use_type:
    mov rdi, [rbp - RCA_CUR]
    mov rsi, [rbp - RCA_FUNC]
    mov rsi, [rsi + PyObject.ob_type]
    mov rsi, [rsi + PyTypeObject.tp_name]
    call rbt_append_cstr
    mov [rbp - RCA_CUR], rax

.rca_tail:
    mov rdi, [rbp - RCA_CUR]
    CSTRING rsi, "()"
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - RCA_MID]
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - RCA_ARG]
    call rbt_append_cstr
    mov rsi, [rbp - RCA_SUF]
    test rsi, rsi
    jz .rca_raise
    mov rdi, rax
    call rbt_append_cstr
.rca_raise:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rbp - RCA_BUF]
    call raise_exception
END_FUNC raise_callable_arg

;; ============================================================================
;; raise_missing_arguments(rdi = the PyFuncObject, rsi = its half-filled frame)
;;   -> does not return: the composed message is raised as a TypeError
;;
;;   f() missing 1 required positional argument: 'b'
;;   f() missing 2 required positional arguments: 'a' and 'b'
;;   f() missing 3 required positional arguments: 'a', 'b', and 'c'
;;   g() missing 1 required keyword-only argument: 'k'
;;
;; What this replaced was the one string "function missing required argument",
;; for every shape of wrong call: it named neither the function, nor the
;; arguments, nor how many were wanted.  It is the most-seen error message in
;; Python -- a typo in a call produces it -- and a test that asserts on a
;; TypeError almost always asserts on this one.
;;
;; A missing POSITIONAL wins.  CPython reports the positionals when any are
;; missing and the keyword-only ones only once the positionals are all
;; filled, so the two never appear in one message; which family it is also
;; decides the middle word and is not derivable from the slot range, because
;; a function with no positional parameters has its keyword-only ones at slot
;; zero.
;;
;; The name list is CPython's and is not a plain join: one name stands bare,
;; two are joined with " and ", and three or more are comma-separated with an
;; Oxford comma before the last.
;;
;; The frame is freed here, because the caller cannot free it first -- the
;; empty slots are what says which arguments are missing.
;; ============================================================================
RMA_FUNC    equ 8
RMA_FRAME_P equ 16
RMA_NAMES   equ 24
RMA_DEST    equ 32
RMA_FIRST   equ 40
RMA_LAST    equ 48
RMA_KWONLY  equ 56
RMA_WRITTEN equ 64
RMA_IDX     equ 72
RMA_SLOTS   equ 80
; The names are user identifiers of any length, so the buffer is derived
; rather than hand-picked and every name is written under a bound: an
; append helper has none of its own, and six long parameter names would
; otherwise run off the end of the frame.
RMA_BUFLEN  equ 512
RMA_ROOM    equ 128            ; kept free, so a name never lands half-written
RMA_BUF     equ RMA_SLOTS + RMA_BUFLEN
RMA_FRAME   equ RMA_BUF        ; + 4 pushes = 640, 16-aligned

extern frame_free

global raise_missing_arguments
DEF_FUNC raise_missing_arguments, RMA_FRAME
    push rbx
    push r12
    push r13
    push r14
    mov rbx, rdi                        ; the function
    mov r12, rsi                        ; its frame
    mov r13, [rbx + PyFuncObject.func_code]
    mov rcx, [r13 + PyCodeObject.co_localsplusnames]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov [rbp - RMA_NAMES], rcx

    ; --- the positional range first: slots [0, co_argcount)
    mov qword [rbp - RMA_FIRST], 0
    mov qword [rbp - RMA_KWONLY], 0
    xor esi, esi
    mov edx, [r13 + PyCodeObject.co_argcount]
    movsxd rax, edx
    mov [rbp - RMA_LAST], rax
    mov rdi, r12
    call .rma_count
    test eax, eax
    jnz .rma_have_range

    ; --- else the keyword-only range: [co_argcount, + co_kwonlyargcount)
    mov qword [rbp - RMA_KWONLY], 1
    mov esi, [r13 + PyCodeObject.co_argcount]
    movsxd rax, esi
    mov [rbp - RMA_FIRST], rax
    mov edx, esi
    add edx, [r13 + PyCodeObject.co_kwonlyargcount]
    movsxd rax, edx
    mov [rbp - RMA_LAST], rax
    mov rdi, r12
    call .rma_count
    test eax, eax
    jz .rma_nothing_missing

.rma_have_range:
    mov r14d, eax                       ; how many are missing, at least 1

    ; --- "<qualname>() missing <n> required "
    mov rdi, [r13 + PyCodeObject.co_qualname]
    test rdi, rdi
    jnz .rma_have_qualname
    mov rdi, [rbx + PyFuncObject.func_name]
    test rdi, rdi
    jz .rma_nothing_missing
.rma_have_qualname:
    lea rsi, [rdi + PyStrObject.data]
    lea rdi, [rbp - RMA_BUF]
    call rbt_append_cstr
    mov rdi, rax
    CSTRING rsi, "() missing "
    call rbt_append_cstr
    mov rdi, rax
    mov esi, r14d
    call msg_append_i64
    mov rdi, rax

    cmp qword [rbp - RMA_KWONLY], 0
    jne .rma_word_kwonly
    CSTRING rsi, " required positional argument"
    jmp .rma_word_chosen
.rma_word_kwonly:
    CSTRING rsi, " required keyword-only argument"
.rma_word_chosen:
    call rbt_append_cstr
    mov rdi, rax
    cmp r14d, 1
    je .rma_singular
    CSTRING rsi, "s"
    call rbt_append_cstr
    mov rdi, rax
.rma_singular:
    CSTRING rsi, ": "
    call rbt_append_cstr
    mov [rbp - RMA_DEST], rax
    mov qword [rbp - RMA_WRITTEN], 0

    ; --- the names, each from co_localsplusnames at its own slot
    mov rax, [rbp - RMA_FIRST]
    mov [rbp - RMA_IDX], rax
.rma_name_loop:
    mov rcx, [rbp - RMA_IDX]
    cmp rcx, [rbp - RMA_LAST]
    jge .rma_names_done
    cmp qword [r12 + PyFrame.localsplus + rcx*8], 0
    jne .rma_name_next
    ; Stop rather than overrun: the room left has to hold a name, its quotes
    ; and a separator.
    mov rax, [rbp - RMA_DEST]
    lea rdx, [rbp - RMA_BUF]
    sub rax, rdx
    cmp rax, RMA_BUFLEN - RMA_ROOM
    jge .rma_names_done

    ; A separator, unless this is the first name.  The last of several takes
    ; ", and " -- or " and " when there are exactly two.
    cmp qword [rbp - RMA_WRITTEN], 0
    je .rma_no_separator
    mov rax, [rbp - RMA_WRITTEN]
    inc rax
    cmp eax, r14d
    jne .rma_plain_separator
    cmp r14d, 2
    jne .rma_oxford
    CSTRING rsi, " and "
    jmp .rma_write_separator
.rma_oxford:
    CSTRING rsi, ", and "
    jmp .rma_write_separator
.rma_plain_separator:
    CSTRING rsi, ", "
.rma_write_separator:
    mov rdi, [rbp - RMA_DEST]
    call rbt_append_cstr
    mov [rbp - RMA_DEST], rax
.rma_no_separator:
    mov rdi, [rbp - RMA_DEST]
    CSTRING rsi, "'"
    call rbt_append_cstr
    mov rdi, rax
    mov rcx, [rbp - RMA_IDX]
    mov rsi, [rbp - RMA_NAMES]
    mov rsi, [rsi + rcx*8]
    lea rsi, [rsi + PyStrObject.data]
    call rbt_append_cstr
    mov rdi, rax
    CSTRING rsi, "'"
    call rbt_append_cstr
    mov [rbp - RMA_DEST], rax
    inc qword [rbp - RMA_WRITTEN]
.rma_name_next:
    inc qword [rbp - RMA_IDX]
    jmp .rma_name_loop

.rma_names_done:
    mov rdi, r12
    call frame_free
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rbp - RMA_BUF]
    call raise_exception

.rma_nothing_missing:
    ; Unreachable from func_call, which only comes here having found an empty
    ; slot.  Kept so that a future caller with a different notion of "filled"
    ; gets a message rather than "missing 0 required arguments".
    mov rdi, r12
    call frame_free
    lea rdi, [rel exc_TypeError_type]
    CSTRING rsi, "function missing required argument"
    call raise_exception

;; rdi = frame, esi = first slot, edx = one past the last
;;   -> eax = how many of those slots are empty
.rma_count:
    xor eax, eax
    mov ecx, esi
.rma_count_loop:
    cmp ecx, edx
    jge .rma_count_done
    movsxd r9, ecx
    cmp qword [rdi + PyFrame.localsplus + r9*8], 0
    jne .rma_count_next
    inc eax
.rma_count_next:
    inc ecx
    jmp .rma_count_loop
.rma_count_done:
    ret
END_FUNC raise_missing_arguments

;; ============================================================================
;; The AttributeError every failed attribute access ends in.  It moved here
;; from object.asm, which crossed the 100k cap when the two attributes CPython
;; hangs on the exception were added -- and this is objerr.asm's subject
;; exactly: a message built into a buffer and handed to a raise that does not
;; return.
;; ============================================================================
extern attr_error_pending
extern current_exception
extern eval_saved_r13
extern eval_exception_unwind
extern value_type
extern module_type
extern str_type
extern exc_AttributeError_type
extern exc_isinstance
extern exc_from_cstr
extern exc_setattr
extern raise_exception_obj
extern str_intern_cstr
extern dict_get
extern obj_decref
extern none_singleton
;; ============================================================================
;; raise_no_attribute(rdi = the object as a Value, rsi = the attribute name,
;;                     edx = 1 for a store or a delete, 0 for a read)
;;   -> does not return: the AttributeError CPython raises
;;
;; The message names both nouns -- a module and a class name THEMSELVES rather
;; than their type, because "'module' object has no attribute 'zzz'" tells a
;; reader nothing about which module was asked.  A read also fills in the two
;; attributes CPython hangs on the exception, `.name` and `.obj`; a store or a
;; delete does not, which is CPython's own split.
;; ============================================================================
RNA_OBJ   equ 8
RNA_NAME  equ 16
RNA_ISSET equ 24            ; 1 for a store or a delete, 0 for a read
RNA_NORET equ 32            ; 1 from set_no_attribute: install, then RETURN
; The message is built in the frame rather than in object.asm's shared rtn_buf:
; that buffer stayed behind, and a raiser that never returns has no reason to
; want a static one.
RNA_BUFSZ equ 512
RNA_BUF   equ 32 + RNA_BUFSZ
RNA_FRAME equ RNA_BUF       ; + 2 pushes, 16-aligned

; .rna_set_attr's own frame, which is its own rbp and not raise_no_attribute's.
RSA_VAL   equ 8
RSA_NAME  equ 16
RSA_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
extern str_type
DEF_FUNC raise_no_attribute, RNA_FRAME
    push rbx
    push r12
    ; A __getattr__ that raised AttributeError already said what it wanted
    ; said.  Replacing it here with a generic message threw that away, so
    ; instance_getattr hands it over with this flag rather than unwinding --
    ; which would skip getattr()'s and hasattr()'s own frames.
    mov [rbp - RNA_NAME], rsi
    mov [rbp - RNA_OBJ], rdi
    mov [rbp - RNA_ISSET], rdx
    mov qword [rbp - RNA_NORET], 0
    cmp qword [rel attr_error_pending], 0
    je .rna_fresh
    mov qword [rel attr_error_pending], 0
    cmp qword [rel current_exception], 0
    je .rna_fresh

    ; CPython's set_attribute_error_context runs after the hook as well, so a
    ; __getattr__ that raised an AttributeError of its own still comes back
    ; carrying the name that was asked for -- unless the hook named one
    ; itself, which is what the probe below leaves alone.
    cmp qword [rbp - RNA_ISSET], 0
    jne .rna_pending_raise
    mov rbx, [rel current_exception]
    mov rdi, rbx
    extern exc_AttributeError_type
    lea rsi, [rel exc_AttributeError_type]
    extern exc_isinstance
    call exc_isinstance
    test eax, eax
    jz .rna_pending_raise
    mov rdi, [rbx + PyExceptionObject.exc_dict]
    test rdi, rdi
    jz .rna_pending_fill
    extern str_intern_cstr
    CSTRING rdi, "name"
    call str_intern_cstr
    test rax, rax
    jz .rna_pending_raise
    mov r12, rax
    mov rdi, [rbx + PyExceptionObject.exc_dict]
    mov rsi, r12
    extern dict_get
    call dict_get
    push rax
    push rax                    ; twice: rsp stays 16-byte aligned
    mov rdi, r12
    call obj_decref
    pop rax
    pop rax
    test rax, rax               ; a Value; 0 is the miss
    jz .rna_pending_fill
    ; AttributeError's constructor writes name=None and obj=None whether or
    ; not the keywords were given (exc_store_named), so "absent" here is None
    ; as well as missing -- CPython's members are NULL in both cases.
    lea rcx, [rel none_singleton]
    cmp rax, rcx
    jne .rna_pending_raise
.rna_pending_fill:
    CSTRING rdi, "name"
    mov rsi, [rbp - RNA_NAME]
    call .rna_set_attr
    CSTRING rdi, "obj"
    mov rsi, [rbp - RNA_OBJ]
    call .rna_set_attr

.rna_pending_raise:
    pop r12
    pop rbx
    leave
    mov [rel eval_saved_r13], r13
    jmp eval_exception_unwind
.rna_fresh:
    push rdi
    call value_type
    pop rdi
    mov r12, rax

    ; A module names itself rather than its type: CPython says
    ; "module 'sys' has no attribute 'zzz'", not "'module' object has ...".
    ; The name is the one thing that tells you WHICH module was asked.
    extern module_type
    lea rcx, [rel module_type]
    cmp r12, rcx
    je .rna_module

    ; And a class names itself, for the same reason: CPython says
    ; "type object 'C' has no attribute 'x'" where this said
    ; "'type' object has no attribute 'x'" -- which names the metatype and so
    ; tells you nothing about which class was asked.  The object here IS the
    ; type, so its own tp_name is the one to print, and TYPE_FLAG_METATYPE on
    ; its type is what says so: it is set on `type`, on both metatypes here,
    ; and on any class deriving from type.
    test r12, r12
    jz .rna_plain
    mov rax, [r12 + PyTypeObject.tp_flags]
    test rax, TYPE_FLAG_METATYPE
    jnz .rna_class

.rna_plain:
    lea rbx, [rbp - RNA_BUF]
    xor ecx, ecx
    mov byte [rbx], 39                  ; '
    inc rcx
    test r12, r12
    jz .rna_after_type
    mov rsi, [r12 + PyTypeObject.tp_name]
    jmp .rna_type

.rna_module:
    lea rbx, [rbp - RNA_BUF]
    xor ecx, ecx
    mov rsi, [rdi + PyModuleObject.mod_name]
    test rsi, rsi
    jz .rna_module_unnamed
    CSTRING rsi, "module '"
    jmp .rna_module_prefix
.rna_module_unnamed:
    CSTRING rsi, "module '?"
.rna_module_prefix:
    movzx eax, byte [rsi]
    test al, al
    jz .rna_module_name
    inc rsi
    mov [rbx + rcx], al
    inc rcx
    jmp .rna_module_prefix
.rna_module_name:
    mov rsi, [rdi + PyModuleObject.mod_name]
    test rsi, rsi
    jz .rna_after_module
    lea rsi, [rsi + PyStrObject.data]
.rna_module_loop:
    movzx eax, byte [rsi]
    test al, al
    jz .rna_after_module
    inc rsi
    cmp rcx, RNA_BUFSZ - 2
    jae .rna_after_module
    mov [rbx + rcx], al
    inc rcx
    jmp .rna_module_loop
.rna_class:
    lea rbx, [rbp - RNA_BUF]
    xor ecx, ecx
    CSTRING rsi, "type object '"
.rna_class_prefix:
    movzx eax, byte [rsi]
    test al, al
    jz .rna_class_name
    inc rsi
    mov [rbx + rcx], al
    inc rcx
    jmp .rna_class_prefix
.rna_class_name:
    mov rsi, [rdi + PyTypeObject.tp_name]   ; a C string, as .rna_type reads it
    test rsi, rsi
    jz .rna_after_module
.rna_class_loop:
    movzx eax, byte [rsi]
    test al, al
    jz .rna_after_module
    inc rsi
    cmp rcx, RNA_BUFSZ - 2
    jae .rna_after_module
    mov [rbx + rcx], al
    inc rcx
    jmp .rna_class_loop

.rna_after_module:
    CSTRING rsi, `' has no attribute '`
    jmp .rna_mid

.rna_type:
    movzx eax, byte [rsi]
    test al, al
    jz .rna_after_type
    inc rsi
    cmp rcx, RNA_BUFSZ - 2
    jae .rna_after_type
    mov [rbx + rcx], al
    inc rcx
    jmp .rna_type
.rna_after_type:
    CSTRING rsi, `' object has no attribute '`
.rna_mid:
    movzx eax, byte [rsi]
    test al, al
    jz .rna_name
    inc rsi
    cmp rcx, RNA_BUFSZ - 2
    jae .rna_name
    mov [rbx + rcx], al
    inc rcx
    jmp .rna_mid
.rna_name:
    mov rsi, [rbp - RNA_NAME]
    test rsi, rsi
    jz .rna_close
    mov rax, [rsi + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rax, rdx
    jne .rna_close
    mov rdx, [rsi + PyStrObject.ob_size]
    lea rsi, [rsi + PyStrObject.data]
    xor eax, eax
.rna_name_copy:
    cmp rax, rdx
    jge .rna_close
    cmp rcx, RNA_BUFSZ - 3
    jae .rna_close
    mov r8b, [rsi + rax]
    mov [rbx + rcx], r8b
    inc rcx
    inc rax
    jmp .rna_name_copy
.rna_close:
    mov byte [rbx + rcx], 39            ; '
    inc rcx
    mov byte [rbx + rcx], 0

    ; PEP 678's two attributes.  They are filled HERE and not in exc_from_cstr,
    ; which every internally raised exception passes through: `name` on a
    ; StopIteration means something else entirely.  What reads them is the
    ; suggestion machinery -- traceback's "Did you mean: ..." and
    ; test_exceptions -- and `getattr(obj, n)` inside a __getattr__ hook, which
    ; asks `e.obj is self` to tell its own miss from a nested one.
    ; A store or a delete gets neither: CPython's set_attribute_error_context
    ; is called only from the generic GET, so `del o.zzz` leaves .name None.
    cmp qword [rbp - RNA_ISSET], 0
    jne .rna_bare
    lea rdi, [rel exc_AttributeError_type]
    extern exc_AttributeError_type
    mov rsi, rbx
    extern exc_from_cstr
    call exc_from_cstr
    test rax, rax
    jz .rna_bare

    ; INSTALLED first, and only then written to.  A fresh exception is
    ; GC-tracked and held by nothing but this register, and `exc_setattr`
    ; allocates twice -- a dict and an interned str -- either of which can
    ; run a collection.  Writing the attributes before the install left the
    ; object collectable for the length of two calls, and what that produced
    ; was a SIGSEGV in `gc_list_remove` from an unrelated `POP_EXCEPT` much
    ; later.  exc_install takes the reference over, so afterwards
    ; current_exception is a real owner.
    mov rdi, rax
    extern exc_install
    call exc_install
    mov rbx, [rel current_exception]
    test rbx, rbx
    jz .rna_installed

    CSTRING rdi, "name"
    mov rsi, [rbp - RNA_NAME]
    call .rna_set_attr
    CSTRING rdi, "obj"
    mov rsi, [rbp - RNA_OBJ]
    call .rna_set_attr

.rna_installed:
    cmp qword [rbp - RNA_NORET], 0
    jne .rna_return
    ; The tail raise_exception has: it does not republish eval_saved_r13
    ; either, because every caller here is inside a helper the opcode called
    ; rather than an opcode that has popped operands of its own.
    leave
    jmp eval_exception_unwind

.rna_bare:
    ; A store, a delete, or an exc_from_cstr that could not allocate.
    cmp qword [rbp - RNA_NORET], 0
    jne .rna_return
    lea rdi, [rel exc_AttributeError_type]
    mov rsi, rbx
    call raise_exception
    ud2

;; A local helper, not a DEF_FUNC: rbx is the exception and rdi/rsi are the
;; name and the value.  A NULL value is None, which is what CPython stores
;; when the raise site has nothing to name.
.rna_set_attr:
    push rbp
    mov rbp, rsp
    sub rsp, RSA_FRAME
    mov [rbp - RSA_VAL], rsi
    call str_intern_cstr
    test rax, rax
    jz .rsa_done
    mov [rbp - RSA_NAME], rax
    mov rdx, [rbp - RSA_VAL]
    test rdx, rdx
    jnz .rsa_have
    lea rdx, [rel none_singleton]
.rsa_have:
    mov rdi, rbx
    mov rsi, rax
    mov ecx, TAG_PTR                    ; rdx is already a Value
    extern exc_setattr
    call exc_setattr
    mov rdi, [rbp - RSA_NAME]
    call obj_decref                     ; str_intern_cstr's; dict_set took one
.rsa_done:
    leave
    ret

.rna_return:
    ; set_no_attribute's exit: the exception is installed and pending, and
    ; the caller hands back NULL itself.
    lea rsp, [rbp - RNA_FRAME - 16]
    pop r12
    pop rbx
    leave
    ret
END_FUNC raise_no_attribute

;; ============================================================================
;; set_no_attribute(rdi = the object as a Value, rsi = the attribute name)
;;   -> returns, with that same AttributeError installed in current_exception
;;
;; raise_no_attribute's read form, for a lookup that has to say "absent" to a
;; caller that may swallow it.  A __slots__ slot never assigned is one:
;; unwinding from inside instance_getattr skipped hasattr()'s and getattr()'s
;; own native frames, so `hasattr(o, "slot")` RAISED instead of answering
;; False.  The prologue is raise_no_attribute's, so its body can be shared.
;; ============================================================================
DEF_FUNC set_no_attribute, RNA_FRAME
    push rbx
    push r12
    mov [rbp - RNA_NAME], rsi
    mov [rbp - RNA_OBJ], rdi
    mov qword [rbp - RNA_ISSET], 0
    mov qword [rbp - RNA_NORET], 1
    xor edx, edx
    jmp raise_no_attribute.rna_fresh
END_FUNC set_no_attribute

;; ============================================================================
;; raise_unexpected_keyword(rdi = the function, rsi = its frame,
;;                          rdx = the keyword's name, a str)
;;   -> does not return: "h() got an unexpected keyword argument 'nosuch'"
;;
;; CPython names the function by its __qualname__ and quotes the keyword; the
;; bare "got an unexpected keyword argument" said neither.  The frame is freed
;; here, as raise_missing_arguments frees it: the caller was part-way through
;; filling it and never gets control back.
;; ============================================================================
RUK_FUNC    equ 8
RUK_FRAME_P equ 16
RUK_NAME    equ 24
RUK_SLOTS   equ 32
; Each append is bounded at 80 bytes by rbt_append_cstr, so two names, the
; fixed text and the quotes fit with room to spare.
RUK_BUFLEN  equ 256
RUK_BUF     equ RUK_SLOTS + RUK_BUFLEN
RUK_FRAME   equ RUK_BUF                 ; 288, 16-aligned with no pushes

global raise_unexpected_keyword
DEF_FUNC raise_unexpected_keyword, RUK_FRAME
    mov [rbp - RUK_FUNC], rdi
    mov [rbp - RUK_FRAME_P], rsi
    mov [rbp - RUK_NAME], rdx

    lea rdi, [rbp - RUK_BUF]
    mov byte [rdi], 0
    mov rax, [rbp - RUK_FUNC]
    mov rcx, [rax + PyFuncObject.func_code]
    mov rsi, [rcx + PyCodeObject.co_qualname]
    test rsi, rsi
    jnz .ruk_have_qualname
    mov rsi, [rax + PyFuncObject.func_name]
    test rsi, rsi
    jz .ruk_no_name
.ruk_have_qualname:
    lea rsi, [rsi + PyStrObject.data]
    call rbt_append_cstr
    mov rdi, rax
    CSTRING rsi, "() "
    call rbt_append_cstr
    mov rdi, rax
.ruk_no_name:
    CSTRING rsi, "got an unexpected keyword argument '"
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - RUK_NAME]
    lea rsi, [rsi + PyStrObject.data]
    call rbt_append_cstr
    mov rdi, rax
    CSTRING rsi, "'"
    call rbt_append_cstr

    mov rdi, [rbp - RUK_FRAME_P]
    call frame_free
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rbp - RUK_BUF]
    call raise_exception
END_FUNC raise_unexpected_keyword
