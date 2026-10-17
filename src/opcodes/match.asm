; opcodes/match.asm - Structural pattern matching and the intrinsics
;
; The MATCH_* family behind `match`, CALL_INTRINSIC_1/2, and the handful of
; introspection opcodes that go with them: GET_LEN, SETUP_ANNOTATIONS,
; LOAD_LOCALS and the LOAD_FROM_DICT_OR_* pair.
;
; Register convention (callee-saved, preserved across handlers):
;   rbx = bytecode instruction pointer (current position in co_code[])
;   r12 = current frame pointer (PyFrame*)
;   r13 = value stack top pointer (Value[], one 64-bit word per slot)
;   r14 = co_consts tuple data pointer (&tuple.ob_item[0])
;
; co_names is accessed via the LOAD_CO_NAMES macro (reads a global).
; ecx = opcode argument on entry (set by eval_dispatch)
; rbx has already been advanced past the 2-byte instruction word.

%include "macros.inc"
%include "object.inc"
%include "opcodes.inc"

section .text

extern eval_dispatch
extern fatal_error
extern async_gen_wrap_value
extern none_singleton
extern bool_true
extern bool_false
extern int_type
extern float_type
extern raise_exception
extern exc_RuntimeError_type
extern exc_SystemError_type
extern exc_StopIteration_type
extern exc_TypeError_type
extern eval_exception_unwind
extern obj_decref
extern prep_reraise_star
extern tuple_new
extern list_type
extern obj_dealloc
extern opcode_table
extern opcode_dispatch_table

;; Stack layout constants for binary_op / compare_op generic paths.
;; After 4 pushes: right, right_tag, left, left_tag
;; Offsets relative to rsp immediately after the 4 pushes.

;; Stack layout constants for op_build_string (DEF_FUNC, 16 bytes).

;; Stack layout constants for op_send (DEF_FUNC, 48 bytes).

;; Stack layout constants for op_match_keys (DEF_FUNC, 32 bytes).
MK_KEYS    equ 8
MK_SUBJ    equ 16
MK_VALS    equ 24
MK_NKEYS   equ 32
MK_I       equ 40           ; the loop index, which used to be pushed.  It
                            ; sits at the very bottom of the carve below --
                            ; the frame is what lint checks, and 40 is the
                            ; aligned size for this handler.
MK_FRAME   equ 40

; --- moved to a sibling file by the split ---
extern op_send

section .text

;; ============================================================================
;; ci_unsupported(const char *prefix, uint32_t sel) -- raise
;; `SystemError: <prefix> N`.  Does not return.
;;
;; The message is built into a static buffer because RAISE takes a literal and
;; the selector is the one thing worth saying.  One process-wide buffer is
;; safe: it is written and handed to raise_exception before anything else can
;; run, and the exception copies it.
;; ============================================================================
section .bss
ci_msgbuf: resb 64
section .text
DEF_FUNC_BARE ci_unsupported
    lea r9, [rel ci_msgbuf]
.cu_copy:
    mov al, [rdi]
    test al, al
    jz .cu_space
    mov [r9], al
    inc rdi
    inc r9
    jmp .cu_copy
.cu_space:
    mov byte [r9], ' '
    inc r9
    mov r10d, 100                       ; the divisor, 100 then 10 then 1
    xor r11d, r11d                      ; a digit has been written
.cu_digit:
    mov eax, esi
    xor edx, edx
    div r10d                            ; eax = digit, edx = what is left
    test eax, eax
    jnz .cu_emit
    test r11d, r11d
    jnz .cu_emit
    cmp r10d, 1
    jne .cu_next
.cu_emit:
    add al, '0'
    mov [r9], al
    inc r9
    mov r11d, 1
.cu_next:
    mov esi, edx
    mov eax, r10d
    xor edx, edx
    mov ecx, 10
    div ecx
    mov r10d, eax
    test r10d, r10d
    jnz .cu_digit
    mov byte [r9], 0
    lea rdi, [rel exc_SystemError_type]
    lea rsi, [rel ci_msgbuf]
    call raise_exception
END_FUNC ci_unsupported

;; ============================================================================
;; op_call_intrinsic_1 - Call 1-arg intrinsic function
;;
;; CALL_INTRINSIC_1 (173): arg selects the intrinsic.
;; Pop TOS, call intrinsic, push result.
;; Key intrinsics:
;;   3 = INTRINSIC_STOPITERATION_ERROR (convert StopIteration to RuntimeError)
;;   5 = INTRINSIC_UNARY_POSITIVE (+x)
;;   6 = INTRINSIC_LIST_TO_TUPLE
;; ============================================================================
DEF_FUNC_BARE op_call_intrinsic_1
    cmp ecx, 1
    je .ci1_print
    cmp ecx, 2
    je .ci1_import_star
    cmp ecx, 3
    je .ci1_stopiter_error
    cmp ecx, 4
    je .ci1_async_gen_wrap
    cmp ecx, 5
    je .ci1_unary_positive
    cmp ecx, 6
    je .ci1_list_to_tuple

    ; PEP 695: 7 = TYPEVAR, 8 = PARAMSPEC, 9 = TYPEVARTUPLE,
    ; 10 = SUBSCRIPT_GENERIC, 11 = TYPEALIAS.  Each takes what is on the stack
    ; and answers the object lib/_typing.py builds from it.
    cmp ecx, 7
    je .ci1_typevar
    cmp ecx, 8
    je .ci1_paramspec
    cmp ecx, 9
    je .ci1_typevartuple
    cmp ecx, 10
    je .ci1_subscript_generic
    cmp ecx, 11
    je .ci1_typealias

    ; Anything else is a real program reaching an intrinsic this interpreter
    ; does not have.  A SystemError naming the selector is what CPython raises
    ; for an intrinsic it cannot dispatch, and it leaves the program able to
    ; report it.  TOS is left where it is: the unwinder empties the stack.
    CSTRING rdi, "CALL_INTRINSIC_1 selector"
    mov esi, ecx
    jmp ci_unsupported

.ci1_typevar:
    CSTRING rdi, "_typevar"
    jmp .ci1_typing_one
.ci1_paramspec:
    CSTRING rdi, "_paramspec"
    jmp .ci1_typing_one
.ci1_typevartuple:
    CSTRING rdi, "_typevartuple"
    jmp .ci1_typing_one
.ci1_subscript_generic:
    CSTRING rdi, "_subscript_generic"
    jmp .ci1_typing_one
;; INTRINSIC_PRINT (arg=1): what makes an interactive statement echo.
;; TOS is the value of a bare expression compiled in "single" mode; it is
;; handed to sys.displayhook, which prints its repr and binds `_`.  The
;; attribute is looked up rather than the builtin called directly, because
;; replacing sys.displayhook is how a program takes the echo over --
;; code.InteractiveInterpreter and IDLE both do.  TOS stays where it is: the
;; POP_TOP that CPython emits after this one drops it.
.ci1_print:
    VPEEK rdi
    push rdi                    ; two pushes: this handler carves no frame
    push rdi
    call intrinsic_display
    pop rdi
    pop rdi
    test eax, eax
    jnz eval_exception_unwind
    DISPATCH

.ci1_typealias:
    CSTRING rdi, "_typealias"
.ci1_typing_one:
    VPOP rsi
    ; Two pushes at each call: this handler carves no frame, so a lone save
    ; leaves the callee 8 out -- and a misaligned call propagates into every
    ; Python frame the interpreter runs beneath it.
    push rsi
    push rsi
    xor edx, edx
    call typing_call
    pop rdi
    pop rdi
    test rax, rax
    jz .ci1_typing_failed
    push rax
    push rax
    DECREF_V rdi, rcx
    pop rax
    pop rax
    VPUSH rax
    DISPATCH
.ci1_typing_failed:
    DECREF_V rdi, rcx
    jmp eval_exception_unwind


;; INTRINSIC_IMPORT_STAR (arg=2): import * from module
;; TOS = module object. Copy module's exported names into frame.locals.
;; If module has __all__, use that list. Otherwise copy all non-underscore names.
IS_SAVED_RBX equ 8      ; the eval-loop bytecode IP, pushed on entry
IS_MOD      equ 16      ; module ptr
IS_MODDICT  equ 24      ; module's __dict__
IS_LOCALS   equ 32      ; frame's locals dict
IS_IDX      equ 40      ; loop index
IS_LIMIT    equ 48      ; capacity or count
IS_ITEMS    equ 56      ; items payload ptr (__all__ path)
IS_ITEM_TAGS equ 64     ; items tag ptr (__all__ path)
IS_SQITEM   equ 72      ; sq_item for an __all__ that is neither list nor tuple
IS_SUBNAME  equ 80      ; the name being imported as a submodule
IS_OWNDICT  equ 88      ; a __dict__ this handler OWNS, or 0.  A module's
                        ; mod_dict is borrowed and needs none of this; an
                        ; object's __dict__ is whatever its type answers with,
                        ; and a property that builds one fresh hands back the
                        ; only reference there is.
IS_FRAME    equ 96      ; sub rsp, 96 (after push rbp + push rbx = 112 total)
; Release the __dict__ this handler took a reference to, if it took one.
%macro IS_DROP_OWNDICT 0
    mov rdi, [rbp - IS_OWNDICT]
    test rdi, rdi
    jz %%none
    mov qword [rbp - IS_OWNDICT], 0
    call obj_decref
%%none:
%endmacro

extern dict_get
extern module_type
extern exc_ImportError_type
extern dict_set
extern str_from_cstr_heap
extern obj_decref

.ci1_import_star:
    ; Pop module from TOS (r13 = eval value stack)
    VPOP_VAL rdi, rsi
    cmp rsi, TAG_PTR
    jne .is_done

    ; Set up stack frame
    push rbp
    mov rbp, rsp
    push rbx                          ; [rbp - IS_SAVED_RBX] = saved eval-loop bytecode IP
    sub rsp, IS_FRAME
    mov qword [rbp - IS_OWNDICT], 0
    mov [rbp - IS_MOD], rdi           ; save module ptr

    ; A module keeps its namespace in mod_dict.  Anything ELSE keeps it in
    ; __dict__, and `from x import *` is allowed over anything else: sys.modules
    ; is an ordinary dict a program may put an ordinary object in, and
    ; importlib's own import_fresh_module does exactly that.  This read
    ; mod_dict off whatever it was handed, so a class registered there gave up
    ; the field that happens to sit at that offset -- a string's characters,
    ; read as a dict pointer, in the crash that found this.
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel module_type]
    cmp rax, rcx
    je .is_real_module
    mov rdi, rax
    mov rsi, rcx
    extern type_is_subtype
    call type_is_subtype
    test eax, eax
    jnz .is_real_module

    CSTRING rdi, "__dict__"
    call str_from_cstr_heap
    mov rbx, rax
    mov rdi, [rbp - IS_MOD]
    mov rsi, rax
    extern obj_getattr_opt
    call obj_getattr_opt
    push rax
    push rax                        ; and a pad: the frame here is odd, so a
                                    ; lone push would misalign the call
    mov rdi, rbx
    call obj_decref
    pop rax
    pop rax
    test rax, rax
    jz .is_no_dict
    V_TEST_PTR rax, rcx
    ja .is_no_dict
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel dict_type]
    cmp rcx, rdx
    je .is_dict_ok
    ; A CLASS answers __dict__ with a mappingproxy, and CPython iterates that
    ; through the mapping protocol.  The dict inside it is the class's own and
    ; the class is alive on the value stack, so unwrapping is safe for exactly
    ; as long as this needs it.
    extern mappingproxy_type
    lea rdx, [rel mappingproxy_type]
    cmp rcx, rdx
    jne .is_no_dict
    push rax
    mov rax, [rax + PyMappingProxyObject.mp_mapping]
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel dict_type]
    cmp rcx, rdx
    pop rcx
    jne .is_no_dict
    ; The PROXY is what is held, not the dict inside it: a class's own dict
    ; would outlive the proxy, but an object that answers __dict__ with a
    ; freshly built mappingproxy owns neither, and the dict goes with it.
    mov [rbp - IS_MODDICT], rax
    mov [rbp - IS_OWNDICT], rcx
    jmp .is_have_dict
.is_dict_ok:
    ; obj_getattr_opt hands back an OWNED reference and this keeps it.  The
    ; object being alive is not enough: `__dict__` is whatever its type
    ; answers with, and a property that builds a dict on each read gives back
    ; the only reference in existence -- releasing it here freed the dict the
    ; walk below was about to read.
    mov [rbp - IS_MODDICT], rax
    mov [rbp - IS_OWNDICT], rax
    jmp .is_have_dict

.is_no_dict:
    RAISE exc_ImportError_type, "from-import-* object has no __dict__ and no __all__"

.is_real_module:
    ; Get mod_dict (+24)
    mov rdi, [rbp - IS_MOD]
    mov rax, [rdi + PyModuleObject.mod_dict]
    test rax, rax
    jz .is_done
    mov [rbp - IS_MODDICT], rax
.is_have_dict:

    ; Get frame locals
    mov rax, [r12 + PyFrame.locals]
    test rax, rax
    jz .is_done
    mov [rbp - IS_LOCALS], rax

    ; Look up "__all__" in mod_dict
    CSTRING rdi, "__all__"
    call str_from_cstr_heap           ; rax = heap str (owned, refcnt=1)
    mov rbx, rax                      ; save key in callee-saved rbx
    mov rdi, [rbp - IS_MODDICT]
    mov rsi, rax                      ; key = "__all__"
    call dict_get                     ; → (rax=value, rdx=tag) or (0, 0)
    V_UNPACK rax, rdx           ; dict_get returns a Value
    ; Save result before DECREF of key
    push rax
    push rdx
    mov rdi, rbx                      ; DECREF "__all__" key string
    call obj_decref
    pop rdx                           ; value tag
    pop rax                           ; value payload

    test edx, edx                     ; TAG_NULL = not found?
    jz .is_no_all

    ;; --- __all__ found ---
    ; It was assumed to be a list or a tuple.  A set has no ob_item, so
    ; `__all__ = {"a"}` read a tuple's field off a set header and segfaulted.
    ; CPython indexes __all__ with PySequence_GetItem, which is the sq_item
    ; slot -- so a str works (a sequence of one-character names, and it really
    ; does bind them) and a set, a dict or an int is
    ; "'X' object does not support indexing".
    mov rbx, rax                      ; rbx = __all__ object
    mov qword [rbp - IS_SQITEM], 0
    ; The tag, not V_TEST_PTR: dict_get's result was already V_UNPACKed, so
    ; rax is a raw payload and `__all__ = 5` would look like a pointer to
    ; address 5.
    cmp edx, TAG_PTR
    jne .is_all_not_seq

    extern list_type
    mov rax, [rbx + PyObject.ob_type]
    lea rdx, [rel list_type]
    cmp rax, rdx
    je .is_all_list
    lea rdx, [rel tuple_type]
    cmp rax, rdx
    je .is_all_tuple

    ; Neither: go through the sequence protocol, as CPython does.
    mov rax, [rax + PyTypeObject.tp_as_sequence]
    test rax, rax
    jz .is_all_not_seq_ptr
    mov rdx, [rax + PySequenceMethods.sq_item]
    test rdx, rdx
    jz .is_all_not_seq_ptr
    mov [rbp - IS_SQITEM], rdx
    mov rax, [rax + PySequenceMethods.sq_length]
    test rax, rax
    jz .is_all_not_seq_ptr
    mov rdi, rbx
    call rax
    mov [rbp - IS_LIMIT], rax
    mov qword [rbp - IS_IDX], 0
    jmp .is_all_loop

.is_all_list:
    mov rcx, [rbx + PyVarObject.ob_size]
    mov [rbp - IS_LIMIT], rcx
    mov rax, [rbx + PyListObject.ob_item]
    jmp .is_all_have_items
.is_all_tuple:
    mov rcx, [rbx + PyVarObject.ob_size]
    mov [rbp - IS_LIMIT], rcx
    mov rax, [rbx + PyTupleObject.ob_item]
.is_all_have_items:
    mov [rbp - IS_ITEMS], rax         ; save payloads ptr
    mov [rbp - IS_ITEM_TAGS], rdx     ; save tags ptr
    mov qword [rbp - IS_IDX], 0

.is_all_loop:
    mov rcx, [rbp - IS_IDX]
    cmp rcx, [rbp - IS_LIMIT]
    jge .is_done

    call .is_all_name                 ; rsi = the name at IS_IDX

    ; Look up name in mod_dict
    mov rdi, [rbp - IS_MODDICT]
    xor edx, edx
    call dict_get                     ; → (rax=value, rdx=value_tag) or (0, 0)
    V_UNPACK rax, rdx           ; dict_get returns a Value
    test edx, edx
    jz .is_all_absent                 ; the module does not define it

    ; dict_set(locals, key=name, value, value_tag, key_tag)
    ; Reload the name: dict_get clobbers the caller-saved registers.
    mov r9, rax                       ; save value payload
    mov r10, rdx                      ; save value tag
    push r9
    push r10
    call .is_all_name
    pop r10
    pop r9
    mov rdi, [rbp - IS_LOCALS]
    mov rdx, r9                       ; value payload
    mov rcx, r10                      ; value tag
    V_PACK rdx, rcx
    call dict_set

.is_all_next:
    inc qword [rbp - IS_IDX]
    jmp .is_all_loop

    ;; .is_all_name -> rsi = the __all__ entry at IS_IDX, borrowed.
    ;; Two shapes: a list or tuple is read straight out of ob_item, and
    ;; anything else goes through the sq_item this type supplied.
.is_all_name:
    sub rsp, 8
    mov rax, [rbp - IS_SQITEM]
    test rax, rax
    jnz .ian_slot
    mov rcx, [rbp - IS_IDX]
    mov rax, [rbp - IS_ITEMS]
    mov rsi, [rax + rcx * 8]
    add rsp, 8
    ret
.ian_slot:
    mov rdi, rbx                      ; the __all__ object
    mov rsi, [rbp - IS_IDX]
    call rax
    V_UNPACK rax, rdx
    mov rsi, rax                      ; an owned one-character str; the locals
                                      ; dict takes its own reference, and the
                                      ; leak is bounded by len(__all__)
    add rsp, 8
    ret

.is_all_absent:
    ; Not in the module's dict.  It may still be a SUBMODULE that the
    ; package's own body never bound: CPython's _handle_fromlist imports each
    ; name in __all__ that the package does not already have, and IMPORT_FROM
    ; next door has always done it -- so `__all__ = ["sub"]` used to raise
    ; here where `from pkg import sub` worked.
    call .is_all_name
    mov [rbp - IS_SUBNAME], rsi
    mov rdi, [rbp - IS_MOD]
    extern import_submodule_attr
    call import_submodule_attr
    test rax, rax
    jz .is_all_really_absent
    mov rdx, rax
    mov rdi, [rbp - IS_LOCALS]
    mov rsi, [rbp - IS_SUBNAME]
    call dict_set
    jmp .is_all_next

.is_all_really_absent:
    ; CPython raises AttributeError here rather than binding what it found and
    ; skipping the rest.  That silence is how lib/copyreg.py came to promise
    ; three functions in __all__ while defining none of them.
    ;
    ; Raising from this hand-rolled frame is safe: eval_exception_unwind
    ; reloads rbx, r12, r13 and rsp from the eval_saved_* globals, and
    ; op_import_from already raises from the same subsystem the same way.
    cmp qword [gs:ThreadState.current_exception], 0
    jne .is_all_propagate
    call .is_all_name
    mov rdi, [rbp - IS_MOD]
    PUBLISH_SP
    xor edx, edx                      ; a get, not a set
    extern raise_no_attribute
    call raise_no_attribute
    ud2
.is_all_propagate:
    ; The submodule was found and its body raised; that is the real cause.
    IS_DROP_OWNDICT
    PUBLISH_SP
    leave
    jmp eval_exception_unwind

.is_all_not_seq_ptr:
    ; Reached once rbx is known to be a real pointer, which is its own Value.
    ; The tag register has been reused for the type walk by this point, so
    ; these paths must not go through the V_PACK below.
    mov rsi, rbx
    jmp .is_all_not_seq_raise
.is_all_not_seq:
    ; raise_type_error_with_name takes a Value; rbx and edx are the unpacked
    ; pair dict_get handed back.
    mov rsi, rbx
    mov ecx, edx
    V_PACK rsi, rcx
.is_all_not_seq_raise:
    ; __all__ came out of the dict borrowed, so it is taken before the dict is
    ; dropped -- and leaked with it, for the reason .is_dict_no_attr gives.
    INCREF_V rsi, rax
    mov [rbp - IS_SUBNAME], rsi
    IS_DROP_OWNDICT
    mov rsi, [rbp - IS_SUBNAME]
    PUBLISH_SP
    CSTRING rdi, `'\x01' object does not support indexing`
    extern raise_type_error_with_name
    jmp raise_type_error_with_name

    ;; --- No __all__: walk dict entries, skip _-prefixed names ---
.is_no_all:
    mov rax, [rbp - IS_MODDICT]
    mov rcx, [rax + PyDictObject.capacity]
    mov [rbp - IS_LIMIT], rcx
    mov qword [rbp - IS_IDX], 0

.is_dict_loop:
    mov rcx, [rbp - IS_IDX]
    cmp rcx, [rbp - IS_LIMIT]
    jge .is_done

    ; Entry address: entries + idx * DICT_ENTRY_SIZE (40)
    mov rax, [rbp - IS_MODDICT]
    mov rsi, [rax + PyDictObject.entries]
    imul rcx, DICT_ENTRY_SIZE
    lea rbx, [rsi + rcx]              ; rbx = entry ptr (callee-saved)

    ; Skip an empty or tombstoned slot.  This tested r8 -- left over from the
    ; previous iteration since the key-tag load it guarded was removed -- so
    ; `from mod import *` bound nothing at all.
    mov rsi, [rbx + DictEntry.key]
    test rsi, rsi
    jz .is_dict_next
    V_UNPACK rsi, r8

    ; Skip names starting with '_'
    cmp r8d, TAG_PTR
    jne .is_dict_copy                 ; non-string → copy
    ; Heap string: check first data byte
    cmp byte [rsi + PyStrObject.data], '_'
    je .is_dict_next

.is_dict_copy:
    ; A MODULE's namespace is its dict, so the value comes straight from the
    ; entry.  Anything else only lent its __dict__ for the NAMES: CPython
    ; getattr's each of them off the object, and for an object whose __dict__
    ; is not its namespace -- one that builds a fresh dict on every read --
    ; the two answer differently, and CPython's answer is the object's.
    cmp qword [rbp - IS_OWNDICT], 0
    je .is_dict_from_entry
    mov rdi, [rbp - IS_MOD]
    ; A key that is not a str cannot be an attribute name; CPython's
    ; PyObject_GetAttr refuses it, and so does obj_getattr_opt by answering 0.
    call obj_getattr_opt
    test rax, rax
    jz .is_dict_no_attr
    mov rdx, rax
    push rdx
    push rdx                          ; and a pad: the frame here is odd
    mov rdi, [rbp - IS_LOCALS]
    mov rsi, [rbx + DictEntry.key]
    call dict_set
    pop rdi
    pop rdi
    DECREF_V rdi, rcx                 ; dict_set took its own reference
    jmp .is_dict_next

.is_dict_from_entry:
    ; dict_set(locals, key Value, value Value)
    mov rdi, [rbp - IS_LOCALS]
    ; rsi = key Value (already set), value comes straight from the entry
    mov rdx, [rbx + DictEntry.value]
    call dict_set

.is_dict_next:
    inc qword [rbp - IS_IDX]
    jmp .is_dict_loop

.is_dict_no_attr:
    ; The name was in __dict__ and the object will not answer it.  CPython
    ; lets PyObject_GetAttr's AttributeError out, naming the attribute.
    ;
    ; The name belongs to the dict, and dropping the dict is what frees it --
    ; rbx points INTO its entry array -- so the name is taken first and the
    ; entry is not read again.  That one reference is leaked: raise_no_attribute
    ; abandons this frame, as every RAISE in the tree does, and leaking a name
    ; is the smaller of the two things that can be leaked here.
    mov rsi, [rbx + DictEntry.key]
    INCREF_V rsi, rax
    mov [rbp - IS_SUBNAME], rsi
    IS_DROP_OWNDICT
    PUBLISH_SP
    mov rdi, [rbp - IS_MOD]
    mov rsi, [rbp - IS_SUBNAME]
    xor edx, edx                      ; a get, not a set
    extern raise_no_attribute
    jmp raise_no_attribute

.is_done:
    IS_DROP_OWNDICT
    ; DECREF module
    mov rdi, [rbp - IS_MOD]
    call obj_decref

    ; Restore and return
    mov rbx, [rbp - IS_SAVED_RBX]                ; restore eval-loop bytecode IP
    leave                             ; mov rsp, rbp; pop rbp
    VPUSH_NONE
    DISPATCH

.ci1_async_gen_wrap:
    ; INTRINSIC_ASYNC_GEN_WRAP: box the value an async generator is about to
    ; yield, so ags_iternext can tell it from an `await` passing through the
    ; same YIELD_VALUE.  Without the box every awaited value is delivered to
    ; the consumer as though it were an item.
    VPOP rdi
    call async_gen_wrap_value
    VPUSH_PTR rax
    DISPATCH

.ci1_stopiter_error:
    ; INTRINSIC_STOPITERATION_ERROR: convert StopIteration to RuntimeError
    ; Only converts if exception IS StopIteration; otherwise re-raise as-is
    mov rax, [r13 - 8]            ; TOS payload (exception)
    test rax, rax
    jz .ci1_si_convert
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel exc_StopIteration_type]
    cmp rcx, rdx
    jne .ci1_si_reraise
.ci1_si_convert:
    ; Pop the exception, raise RuntimeError instead
    VPOP rdi
    DECREF_V rdi, rsi
    PUBLISH_SP  ; update — popped and DECREF'd
    RAISE exc_RuntimeError_type, "generator raised StopIteration"
.ci1_si_reraise:
    ; Not StopIteration — pop from TOS, set as current_exception, re-raise
    VPOP_VAL rax, rsi              ; exception (ref transferred from stack)
    PUBLISH_SP  ; update — popped and transferred
    mov rcx, [gs:ThreadState.current_exception]
    mov [gs:ThreadState.current_exception], rax
    cmp rcx, rax
    je .ci1_si_go
    test rcx, rcx
    jz .ci1_si_go
    push rax
    push rax                          ; and a pad: no frame here, so a lone
                                      ; push leaves the call 8 out
    mov rdi, rcx
    call obj_decref
    pop rax
    pop rax
.ci1_si_go:
    ; This is a re-raise, so it adds no traceback entry -- the frame already
    ; recorded one where the exception was first raised.
    mov byte [gs:ThreadState.tb_suppress_frame], 1
    jmp eval_exception_unwind

.ci1_unary_positive:
    ; +x calls the type's nb_positive.  This used to only *test* the slot and
    ; leave the value alone, which was indistinguishable from identity for
    ; int and float -- but a user class defining __pos__ now has a real slot,
    ; and ignoring it returned the operand unchanged.
    mov rax, [r13 - 8]
    V_TEST_PTR rax, rcx
    ja .ci1_pos_done            ; an int or float immediate: +x is x
    mov rcx, [rax + PyObject.ob_type]
    mov rcx, [rcx + PyTypeObject.tp_as_number]
    test rcx, rcx
    jz .ci1_pos_error
    mov rcx, [rcx + PyNumberMethods.nb_positive]
    test rcx, rcx
    jz .ci1_pos_error
    push rax
    push rax                    ; twice: keep rsp 16-byte aligned
    mov rdi, rax                ; a pointer is its own Value
    call rcx                    ; nb_positive returns a Value, or NULL
    test rax, rax
    jz .ci1_pos_declined        ; a slot may decline; storing the NULL put a
    mov [r13 - 8], rax          ; raw 0 on the value stack for later to find
    pop rdi
    pop rdi                     ; rdi = the operand, still owned
    DECREF_V rdi, rcx

.ci1_pos_done:
    DISPATCH

.ci1_pos_declined:
    pop rdi
    pop rdi
.ci1_pos_error:
    RAISE exc_TypeError_type, "bad operand type for unary +"

.ci1_list_to_tuple:
    ; Convert list to tuple
    VPOP_VAL rdi, rsi           ; rdi = list, rsi = tag
    cmp rsi, TAG_PTR
    jne .ci1_l2t_error
    push rdi                   ; save for DECREF

    ; Get list size and items
    mov rcx, [rdi + PyListObject.ob_size]
    mov rsi, [rdi + PyListObject.ob_item]
    push rcx
    push rsi
    push rdx

    ; Create tuple of same size
    mov rdi, rcx
    call tuple_new
    ; (tuple in rax — use stack, do NOT clobber rbx which is the bytecode IP)
    pop r11                    ; tags ptr
    pop rsi                    ; payloads ptr
    pop rcx                    ; count
    push rax                   ; save tuple

    ; Copy items from list to tuple, INCREF each
    xor edx, edx
.ci1_l2t_loop:
    cmp rdx, rcx
    jge .ci1_l2t_done
    push rcx
    push rdx
    push rsi

    mov rdi, [rsi + rdx * 8]        ; item Value
    mov rax, [rsp + 24]             ; tuple from stack
    mov r8, [rax + PyTupleObject.ob_item]
    mov [r8 + rdx * 8], rdi
    INCREF_V rdi, r9

    pop rsi
    pop rdx
    pop rcx
    inc rdx
    jmp .ci1_l2t_loop

.ci1_l2t_done:
    pop rax                    ; tuple
    VPUSH_PTR rax

    ; DECREF list
    pop rdi
    DECREF_REG rdi

    DISPATCH

.ci1_l2t_error:
    RAISE exc_TypeError_type, "list expected"
END_FUNC op_call_intrinsic_1

;; ============================================================================
;; intrinsic_display(rdi = Value) -> rax = 0 ok, 1 with an exception pending
;;
;; INTRINSIC_PRINT's body, out of line because the handler carves no frame.
;; Calls sys.displayhook(value) -- the attribute, so that a program which
;; replaced it is the one that decides what an interactive statement echoes.
;; With no sys module there is nothing to display and nothing to report.
;; ============================================================================
ID_VAL    equ 8
ID_NAME   equ 16
ID_HOOK   equ 24
ID_FRAME  equ 32            ; 0 pushes, 16-aligned
DEF_FUNC_LOCAL intrinsic_display, ID_FRAME
    mov [rbp - ID_VAL], rdi
    extern sys_module_obj
    mov rax, [rel sys_module_obj]
    test rax, rax
    jz .id_ok
    mov [rbp - ID_HOOK], rax

    CSTRING rdi, "displayhook"
    extern str_from_cstr_heap
    call str_from_cstr_heap
    mov [rbp - ID_NAME], rax
    mov rdi, [rbp - ID_HOOK]
    mov rsi, rax
    extern obj_getattr_opt
    call obj_getattr_opt
    mov [rbp - ID_HOOK], rax
    mov rdi, [rbp - ID_NAME]
    extern obj_decref
    call obj_decref
    mov rax, [rbp - ID_HOOK]
    test rax, rax
    jz .id_ok                   ; no displayhook: nothing to echo through

    sub rsp, 16
    mov rax, [rbp - ID_VAL]
    mov [rsp], rax
    mov rdi, [rbp - ID_HOOK]
    mov rsi, rsp
    mov edx, 1
    extern obj_call_n
    call obj_call_n
    add rsp, 16
    mov [rbp - ID_VAL], rax     ; the hook's result, or 0
    ; A Value: sys.displayhook is whatever a program put there, and obj_decref
    ; would write through an immediate.
    mov rdi, [rbp - ID_HOOK]
    DECREF_V rdi, rcx
    mov rax, [rbp - ID_VAL]
    test rax, rax
    jz .id_raised
    DECREF_V rax, rcx
.id_ok:
    xor eax, eax
    leave
    ret
.id_raised:
    mov eax, 1
    leave
    ret
END_FUNC intrinsic_display

;; ============================================================================
;; op_get_len - Push len(TOS) without popping TOS
;;
;; Opcode 30: GET_LEN
;; Used by match statements: push len, keep original on stack.
;; ============================================================================

DEF_FUNC_BARE op_get_len
    ; PEEK TOS (don't pop)
    mov rdi, [r13 - 8]
    V_TEST_PTR rdi, rax
    ja .gl_error_nopop          ; an immediate has no len()
    push rdi                    ; save obj

    ; Get length
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_sequence]
    test rax, rax
    jz .gl_try_mapping
    mov rax, [rax + PySequenceMethods.sq_length]
    test rax, rax
    jz .gl_try_mapping
    ; One saved word is an odd number of slots, and rsp is 16-byte aligned on
    ; entry to a handler.  The pad is local to the call because .gl_error_nopop
    ; is reached before the push and must not unwind it.
    sub rsp, 8
    call rax
    add rsp, 8
    jmp .gl_got_len

.gl_try_mapping:
    pop rdi
    push rdi
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_mapping]
    test rax, rax
    jz .gl_error
    mov rax, [rax + PyMappingMethods.mp_length]
    test rax, rax
    jz .gl_error
    sub rsp, 8                  ; the same pad, for the same reason
    call rax
    add rsp, 8

.gl_got_len:
    pop rdi                     ; discard saved obj
    ; Convert length (in rax) to SmallInt and push
    VPUSH_INT rax, r15
    DISPATCH

.gl_error:
    pop rdi
.gl_error_nopop:
    RAISE exc_TypeError_type, "object has no len()"
END_FUNC op_get_len

;; ============================================================================
;; op_setup_annotations - Create __annotations__ dict in locals
;;
;; Opcode 85: SETUP_ANNOTATIONS
;; ============================================================================
extern dict_new
extern dict_set

; A handler is entered 16-byte ALIGNED, so `push rbp` plus two saves leaves rsp
; 8 out at every call below.  The third push is the slot that puts it back --
; and it has to be a push rather than a DEF_FUNC frame, because this handler's
; epilogue is a hand-written `pop rbp` with no `leave`, so a frame would never
; be discarded and the eval loop's stack would sink 8 bytes per execution.
DEF_FUNC op_setup_annotations
    push rbx
    push r12                    ; save eval loop r12
    push r13                    ; unused; the alignment slot

    ; Check if locals dict exists
    mov rbx, [r12 + PyFrame.locals]
    test rbx, rbx
    jz .sa_done

    ; The key first: both arms below need it.
    extern str_from_cstr_heap
    CSTRING rdi, "__annotations__"
    call str_from_cstr_heap
    mov r13, rax                ; the key, owned

    ; A frame's locals need not be a dict -- exec() takes any mapping, and
    ; CPython's SETUP_ANNOTATIONS has an arm for each.  This one handed
    ; whatever it found to dict_set, which probed the object's header as a
    ; hash table; CPython's test_grammar.test_var_annot_refleak passes a
    ; class with __getitem__ and __setitem__ and died there.
    extern dict_type
    mov rax, [rbx + PyObject.ob_type]
    lea rcx, [rel dict_type]
    cmp rax, rcx
    je .sa_dict
    REQUIRE_DICT_TYPE rax, rcx, .sa_mapping

.sa_dict:
    ; Only when it is not already there.  Installing a fresh one unconditionally
    ; discarded whatever an enclosing class body had put in it -- CPython looks
    ; first too.
    extern dict_get
    mov rdi, rbx
    mov rsi, r13
    call dict_get
    test rax, rax
    jnz .sa_have

    call dict_new
    mov r12, rax                ; the new annotations dict
    mov rdi, rbx
    mov rsi, r13
    mov rdx, r12
    call dict_set
    mov rdi, r12
    call obj_decref             ; dict_set took its own reference
    jmp .sa_have

.sa_mapping:
    ; Through mapping_getitem_opt rather than mp_subscript: a heaptype's slot
    ; does not RETURN when __getitem__ raises, so the miss this arm exists to
    ; absorb would escape as a KeyError from an opcode that has nothing to do
    ; with it.
    mov rdi, rbx
    mov rsi, r13
    extern mapping_getitem_opt
    call mapping_getitem_opt
    test rax, rax
    jz .sa_map_missing
    mov rdi, rax
    DECREF_V rdi, rsi           ; it exists; only its presence mattered
    jmp .sa_have

.sa_map_missing:
    ; A miss RAISES here where a dict answers NULL.  CPython clears a KeyError
    ; and lets anything else through; clearing whatever it was keeps an
    ; exception from a mapping's __getitem__ out of an opcode that has nothing
    ; to do with it.
    mov rdi, [gs:ThreadState.current_exception]
    test rdi, rdi
    jz .sa_map_make
    mov qword [gs:ThreadState.current_exception], 0
    call obj_decref
.sa_map_make:
    call dict_new
    mov r12, rax
    mov rax, [rbx + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_mapping]
    mov rax, [rax + PyMappingMethods.mp_ass_subscript]
    test rax, rax
    jz .sa_map_free
    mov rdi, rbx
    mov rsi, r13
    mov rdx, r12
    call rax
.sa_map_free:
    mov rdi, r12
    call obj_decref

.sa_have:
    mov rdi, r13
    call obj_decref             ; the key

.sa_done:
    pop r13
    pop r12
    pop rbx
    pop rbp
    DISPATCH
END_FUNC op_setup_annotations

;; ============================================================================
;; op_load_locals - Push locals dict
;;
;; Opcode 87: LOAD_LOCALS
;; ============================================================================
DEF_FUNC_BARE op_load_locals
    mov rax, [r12 + PyFrame.locals]
    test rax, rax
    jz .ll_error
    INCREF rax
    VPUSH_PTR rax
    DISPATCH
.ll_error:
    RAISE exc_RuntimeError_type, "no locals dict"
END_FUNC op_load_locals

;; ============================================================================
;; op_load_from_dict_or_globals - Load from dict on TOS, fallback to globals
;;
;; Opcode 175: LOAD_FROM_DICT_OR_GLOBALS
;; Used in class body comprehensions.
;; ============================================================================
extern dict_get

DEF_FUNC_BARE op_load_from_dict_or_globals
    ; ecx = name index (payload array: 8-byte stride)
    shl ecx, 3
    LOAD_CO_NAMES rsi
    mov rsi, [rsi + rcx]       ; name string
    push rsi

    ; Pop dict from TOS
    VPOP_VAL rdi, r8
    push rdi                    ; save dict
    cmp r8, TAG_PTR
    jne .lfdg_not_dict

    ; Try dict first
    mov rsi, [rsp + 8]         ; name
    call dict_get
    test rax, rax               ; dict_get answers with a Value; 0 is the miss
    jnz .lfdg_found

    ; Try globals
    mov rdi, [r12 + PyFrame.globals]
    mov rsi, [rsp + 8]         ; name
    call dict_get
    test rax, rax               ; dict_get answers with a Value; 0 is the miss
    jnz .lfdg_found

    ; DECREF dict (owned ref from TOS) before builtins lookup
    pop rdi                     ; saved dict
    DECREF rdi
    pop rsi                     ; name

    ; Try builtins
    mov rdi, [r12 + PyFrame.builtins]
    call dict_get
    test rax, rax               ; dict_get answers with a Value; 0 is the miss
    jnz .lfdg_found_no_pop

    ; Not found
    extern exc_NameError_type
    RAISE exc_NameError_type, "name not found"

.lfdg_found:
    ; dict_get answers with a VALUE, and rdx is whatever its probe left there.
    ; Reading it as a tag skipped the INCREF whenever it did not look like
    ; TAG_PTR and pushed a BORROWED reference: `class Inner[T](B)` with B a
    ; class attribute freed the base out from under the class being built,
    ; and which names it happened to was a function of the probe.
    INCREF_V rax, rcx
    ; Save the result across the DECREF
    push rax
    push rax                    ; twice: rsp keeps its alignment
    mov rdi, [rsp + 16]        ; saved dict (shifted by 2 pushes)
    DECREF rdi
    pop rax
    pop rax
    add rsp, 16                 ; pop saved dict + name
    VPUSH rax
    DISPATCH

.lfdg_not_dict:
    ; Not a dict on TOS
    pop rdi
    pop rsi
    RAISE exc_TypeError_type, "dict expected"

.lfdg_found_no_pop:
    ; dict already DECREFed in builtins path; a Value, as above
    INCREF_V rax, rcx
    VPUSH rax
    DISPATCH
END_FUNC op_load_from_dict_or_globals

;; ============================================================================
;; op_load_from_dict_or_deref - Load from dict on TOS, fallback to cell deref
;;
;; Opcode 176: LOAD_FROM_DICT_OR_DEREF
;; Used in class bodies that access closure variables directly (e.g. val = x).
;; Pop dict from TOS. Try dict[name] first. If not found, fall back to
;; loading through cell at localsplus[arg] (same as LOAD_DEREF).
;; ============================================================================
global op_load_from_dict_or_deref

LFDOD_DICT  equ 8
LFDOD_ARG   equ 16
LFDOD_FRAME equ 24          ; + 0 pushes = 16

DEF_FUNC op_load_from_dict_or_deref, LFDOD_FRAME
    mov [rbp - LFDOD_ARG], ecx    ; save arg (localsplus index)

    ; The name is co_localsplusnames[arg], which is what the argument INDEXES.
    ; It used to come from co_names at the same index -- a different tuple
    ; entirely -- so a class body that reads a closure variable read whatever
    ; name happened to sit there: `class C[T]` with an annotation of T got
    ; co_names[1], which is `__module__`, and the annotation came out as
    ; '__main__'.
    mov rax, [r12 + PyFrame.code]
    mov rax, [rax + PyCodeObject.co_localsplusnames]
    test rax, rax
    jz .lfdod_name_fallback
    movsxd rcx, ecx
    cmp rcx, [rax + PyTupleObject.ob_size]
    jae .lfdod_name_fallback
    mov rax, [rax + PyTupleObject.ob_item]
    mov rsi, [rax + rcx*8]
    jmp .lfdod_have_name
.lfdod_name_fallback:
    mov ecx, [rbp - LFDOD_ARG]
    shl ecx, 3
    LOAD_CO_NAMES rsi
    mov rsi, [rsi + rcx]          ; name string
.lfdod_have_name:

    ; Pop dict from TOS
    VPOP_VAL rdi, r8
    mov [rbp - LFDOD_DICT], rdi   ; save dict
    cmp r8, TAG_PTR
    jne .lfdod_error

    ; Try dict first (the name is a string, so it is already a Value)
    call dict_get
    V_UNPACK rax, rdx           ; dict_get returns a Value
    test edx, edx
    jnz .lfdod_found

    ; Not in dict — fall back to cell deref (like LOAD_DEREF)
    mov ecx, [rbp - LFDOD_ARG]
    mov rax, [r12 + PyFrame.localsplus + rcx*8]  ; cell object
    test rax, rax
    jz .lfdod_error
    mov rax, [rax + PyCellObject.ob_ref]
    test rax, rax                 ; 0 means an empty cell
    jz .lfdod_error
    V_UNPACK rax, rdx

.lfdod_found:
    ; INCREF result (borrowed ref) before DECREF dict
    INCREF_VAL rax, rdx
    ; Save result across DECREF of owned dict ref
    push rax
    push rdx
    mov rdi, [rbp - LFDOD_DICT]
    DECREF rdi
    pop rdx
    pop rax
    VPUSH_VAL rax, rdx
    leave
    DISPATCH

.lfdod_error:
    RAISE exc_NameError_type, "free variable referenced before assignment"
END_FUNC op_load_from_dict_or_deref

;; ============================================================================
;; op_match_mapping - Check if TOS is a mapping type
;;
;; Opcode 31: MATCH_MAPPING
;; Push True if TOS is dict/mapping, False otherwise. Don't pop TOS.
;; ============================================================================
extern dict_type

DEF_FUNC_BARE op_match_mapping
    mov rdi, [r13 - 8]            ; peek TOS
    V_TEST_PTR rdi, rax
    ja .mm_false                   ; an immediate is not a mapping
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel dict_type]
    cmp rax, rcx
    je .mm_true

    ; Having mp_subscript is not enough: a list has one, so a list answered
    ; yes here and MATCH_KEYS then looked keys up in it and crashed.  CPython
    ; asks a type flag only real mappings carry; the nearest thing available is
    ; dict and its subclasses, so anything else that is subscriptable is
    ; rejected -- the same shape as MATCH_SEQUENCE excluding dict on its side.
    sub rsp, 8                 ; pad: rsp is 16-aligned on entry to a
                               ; handler, so a call needs an even push list
    push rdi
    mov rdi, rax
    lea rsi, [rel dict_type]
    extern type_is_subtype
    call type_is_subtype
    pop rdi
    add rsp, 8
    test eax, eax
    jz .mm_false
.mm_true:
    lea rax, [rel bool_true]
    INCREF rax
    VPUSH_PTR rax
    DISPATCH
.mm_false:
    lea rax, [rel bool_false]
    INCREF rax
    VPUSH_PTR rax
    DISPATCH
END_FUNC op_match_mapping

;; ============================================================================
;; op_match_sequence - Check if TOS is a sequence type
;;
;; Opcode 32: MATCH_SEQUENCE
;; Push True if TOS is list/tuple/sequence (not str/bytes/dict). Don't pop TOS.
;; ============================================================================
extern tuple_type
extern str_type
extern bytes_type

DEF_FUNC_BARE op_match_sequence
    mov rdi, [r13 - 8]            ; peek TOS
    V_TEST_PTR rdi, rax
    ja .ms_false                   ; an immediate is not a sequence
    mov rax, [rdi + PyObject.ob_type]
    ; Exclude str, bytes, dict
    lea rcx, [rel str_type]
    cmp rax, rcx
    je .ms_false
    lea rcx, [rel bytes_type]
    cmp rax, rcx
    je .ms_false
    lea rcx, [rel dict_type]
    cmp rax, rcx
    je .ms_false
    ; Check list or tuple type directly
    lea rcx, [rel list_type]
    cmp rax, rcx
    je .ms_true
    lea rcx, [rel tuple_type]
    cmp rax, rcx
    je .ms_true
    ; Check tp_as_sequence with sq_item
    mov rax, [rax + PyTypeObject.tp_as_sequence]
    test rax, rax
    jz .ms_false
    mov rax, [rax + PySequenceMethods.sq_item]
    test rax, rax
    jz .ms_false
.ms_true:
    lea rax, [rel bool_true]
    INCREF rax
    VPUSH_PTR rax
    DISPATCH
.ms_false:
    lea rax, [rel bool_false]
    INCREF rax
    VPUSH_PTR rax
    DISPATCH
END_FUNC op_match_sequence

;; ============================================================================
;; op_match_keys - Match mapping keys
;;
;; Opcode 33: MATCH_KEYS
;; TOS = keys tuple, TOS1 = subject (mapping)
;; If all keys in tuple exist in subject, push tuple of values + True
;; Otherwise push False
;; ============================================================================
DEF_FUNC op_match_keys, MK_FRAME

    ; TOS = keys tuple, TOS1 = subject (16 bytes/slot)
    ; Peek at both — don't pop either! Push result on top.
    mov rax, [r13 - 8]            ; keys tuple (TOS)
    mov [rbp - MK_KEYS], rax
    mov rax, [r13 - 16]           ; subject (TOS1)
    mov [rbp - MK_SUBJ], rax

    ; Allocate values tuple
    mov rax, [rbp - MK_KEYS]
    mov rdi, [rax + PyTupleObject.ob_size]
    mov [rbp - MK_NKEYS], rdi     ; save nkeys
    call tuple_new
    mov [rbp - MK_VALS], rax      ; values tuple

    ; The index lives in the frame, not on the machine stack.  It used to be
    ; pushed across dict_get, which clobbers rdx -- and that lone push left
    ; the call 8 out, which propagates into every frame the interpreter runs
    ; beneath it.  A slot costs the same and says what it holds.
    mov qword [rbp - MK_I], 0

.mk_loop:
    mov rdx, [rbp - MK_I]
    cmp rdx, [rbp - MK_NKEYS]
    jge .mk_success

    ; Get key
    mov rax, [rbp - MK_KEYS]
    mov rsi, [rax + PyTupleObject.ob_item]        ; payloads
    mov rsi, [rsi + rdx*8]                         ; key payload

    ; Look up in subject
    mov rdi, [rbp - MK_SUBJ]
    call dict_get
    V_UNPACK rax, rdx           ; dict_get returns a Value
    test edx, edx
    jz .mk_fail

    mov r9, rdx                 ; r9 = value tag from dict_get

    ; Store value in values tuple
    mov rdx, [rbp - MK_I]
    INCREF_VAL rax, r9          ; tag-aware INCREF
    mov rcx, [rbp - MK_VALS]
    mov r8, [rcx + PyTupleObject.ob_item]         ; payloads
    V_PACK rax, r9
    mov [r8 + rdx * 8], rax

    inc qword [rbp - MK_I]
    jmp .mk_loop

.mk_success:
    ; Push values tuple on top (stack: subject, keys, values_tuple)
    mov rax, [rbp - MK_VALS]
    VPUSH_PTR rax
    jmp .mk_done

.mk_fail:
    ; No pop: the index is a frame slot now, not a push.
    ; DECREF partial values tuple
    mov rdi, [rbp - MK_VALS]
    call obj_decref
    ; Push None on top to indicate failure (stack: subject, keys, None)
    lea rax, [rel none_singleton]
    INCREF rax
    VPUSH_PTR rax

.mk_done:
    leave
    DISPATCH
END_FUNC op_match_keys

;; ============================================================================
;; op_match_class - Structural pattern matching: match class
;;
;; Opcode 152: MATCH_CLASS
;; Stack before: subject(TOS2), class(TOS1), kw_attrs_tuple(TOS)
;; Arg (ecx) = npos (number of positional sub-patterns)
;; Stack after: attrs_tuple (success) or None (failure)
;; All 3 inputs consumed.
;; ============================================================================

;; Stack layout constants (MC_ prefix)
MC_SUBJ      equ 8
MC_CLASS     equ 16
MC_KWATTRS   equ 24
MC_NPOS      equ 32
MC_RESULT    equ 40
MC_MATCHARGS equ 48
MC_IDX       equ 56
MC_SUBJ_TAG  equ 64
MC_ORIGIN    equ 72   ; the subject's type, for the __match_args__ walk
MC_BADTYPE   equ 80   ; the type named in a __match_args__ TypeError
MC_BADVAL    equ 88   ; and the payload it came from, before the release
MC_BADTAG    equ 96   ; with its tag: dict_get answers the legacy pair here
; The three __match_args__ messages carry a class name and sometimes two
; counts, so they are composed rather than literal.  Derived, so growing the
; scalars above cannot walk into the buffer.
; A handler is entered aligned, so the frame has to be 8 mod 16 with no
; pushes -- which is what the 104 this replaced was.
MC_BUFLEN    equ 240
MC_BUF       equ 104 + MC_BUFLEN
MC_FRAME     equ MC_BUF         ; + 0 pushes = 344, which is 8 mod 16

extern str_type

DEF_FUNC op_match_class, MC_FRAME

    ; Pop all 3 inputs
    VPOP rax                        ; kw_attrs tuple (TOS)
    mov [rbp - MC_KWATTRS], rax
    VPOP rax                        ; class (TOS1)
    mov [rbp - MC_CLASS], rax
    VPOP_VAL rax, rdx               ; subject (TOS2) + tag
    mov [rbp - MC_SUBJ], rax
    mov [rbp - MC_SUBJ_TAG], rdx

    mov [rbp - MC_NPOS], rcx        ; save npos
    mov qword [rbp - MC_RESULT], 0  ; result tuple (NULL initially)
    mov qword [rbp - MC_MATCHARGS], 0  ; __match_args__ (NULL initially)

    ;; --- isinstance check ---
    ;; Get subject's type (SmallInt/None-aware)
    mov rax, [rbp - MC_SUBJ]
    cmp qword [rbp - MC_SUBJ_TAG], TAG_SMALLINT
    je .mc_smallint_type
    cmp qword [rbp - MC_SUBJ_TAG], TAG_FLOAT
    je .mc_float_type
    ; Everything else is a real pointer -- None included, since it is an
    ; ordinary heap singleton.  (The arm here used to be `jz .mc_none_type`,
    ; which tests the same flag as the `je` above it: the None arm was dead
    ; and a float subject fell into the dereference below.)
    mov rdx, [rax + PyObject.ob_type]
    jmp .mc_got_type

.mc_smallint_type:
    lea rdx, [rel int_type]
    jmp .mc_got_type

.mc_float_type:
    lea rdx, [rel float_type]

.mc_got_type:
    ; rdx = subject's type; the test is over its MRO, not its tp_base chain
    mov [rbp - MC_ORIGIN], rdx
    mov rdi, rdx
    mov rsi, [rbp - MC_CLASS]
    extern type_is_subtype
    call type_is_subtype
    test eax, eax
    jnz .mc_isinstance_ok
    ; Not an instance of class — fail
    jmp .mc_fail

.mc_isinstance_ok:
    ;; --- Get __match_args__ if npos > 0 ---
    mov rcx, [rbp - MC_NPOS]
    test rcx, rcx
    jz .mc_no_matchargs_needed

    ; Look up __match_args__ on the class via tp_dict chain
    mov r8, [rbp - MC_CLASS]       ; start at class
.mc_matchargs_walk:
    mov rdi, [r8 + PyTypeObject.tp_dict]
    test rdi, rdi
    jz .mc_matchargs_next_base

    ; Look up "__match_args__" in dict
    push r8
    push rdi                        ; save dict
    lea rdi, [rel .mc_matchargs_cstr]
    call str_from_cstr_heap
    mov rsi, rax                    ; rsi = "__match_args__" str obj
    pop rdi                         ; restore dict
    push rsi                        ; save string for DECREF
    call dict_get
    V_UNPACK rax, rdx           ; dict_get returns a Value
    pop rsi                         ; rsi = string to DECREF
    push rdx                        ; save dict_get tag
    push rax                        ; save dict_get payload
    push rax                        ; and a pad: r8 is still down there, so
                                    ; these two alone leave the call 8 out
    mov rdi, rsi
    call obj_decref
    pop rax
    pop rax                         ; restore dict_get payload
    pop rdx                         ; restore dict_get tag
    pop r8                          ; restore type pointer

    test edx, edx
    jnz .mc_matchargs_found

.mc_matchargs_next_base:
    MRO_NEXT r8, [rbp - MC_ORIGIN]
    test r8, r8
    jnz .mc_matchargs_walk

    ; __match_args__ nowhere on the MRO and npos > 0.  CPython raises
    ; "accepts 0 positional sub-patterns"; MC_MATCHARGS is still 0, which is
    ; the count the message reads.
    jmp .mc_too_few

.mc_matchargs_found:
    ; rax = whatever the MRO answered with (borrowed, from dict_get).  It has
    ; to BE a tuple: this read ob_size and ob_item off it unchecked, and
    ; `__match_args__ = None` walked a pointer made of the singleton's
    ; header.  CPython names the class and what it got.
    ; An EXACT tuple, as CPython's PyTuple_CheckExact demands: a tuple
    ; subclass is refused there too.
    ;
    ; rax and edx are a PAYLOAD and a TAG here, not a Value -- that is what
    ; dict_get was unpacked into above -- so the question is asked of the
    ; tag.  Asking V_TEST_PTR of the payload instead said that the payload of
    ; `__match_args__ = 1` was a pointer, because 1 is a perfectly good
    ; address, and the dereference below read type 1.
    mov [rbp - MC_BADVAL], rax
    mov [rbp - MC_BADTAG], rdx
    cmp edx, TAG_PTR
    jne .mc_matchargs_not_tuple
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel tuple_type]
    cmp rcx, rdx
    jne .mc_matchargs_not_tuple
    INCREF rax
    mov [rbp - MC_MATCHARGS], rax

    ; Verify length >= npos
    mov rcx, [rbp - MC_NPOS]
    mov rdx, [rax + PyTupleObject.ob_size]
    cmp rdx, rcx
    jl .mc_too_few                  ; CPython raises here rather than failing

.mc_no_matchargs_needed:
    ;; --- Allocate result tuple: npos + len(kw_attrs) ---
    mov rdi, [rbp - MC_NPOS]
    mov rax, [rbp - MC_KWATTRS]
    add rdi, [rax + PyTupleObject.ob_size]
    call tuple_new
    mov [rbp - MC_RESULT], rax

    ;; --- Positional loop: i=0..npos-1 ---
    mov qword [rbp - MC_IDX], 0
.mc_pos_loop:
    mov rcx, [rbp - MC_IDX]
    cmp rcx, [rbp - MC_NPOS]
    jge .mc_kw_start

    ; Get attr name from __match_args__[i]
    mov rax, [rbp - MC_MATCHARGS]
    mov rsi, [rax + PyTupleObject.ob_item]       ; payloads
    mov rsi, [rsi + rcx*8]                       ; name string
    ; It has to BE a string: tp_getattr is about to read PyStrObject.data off
    ; it, and an int element is an immediate with no header at all.
    V_TEST_PTR rsi, rdx
    ja .mc_bad_element
    mov rdx, [rsi + PyObject.ob_type]
    lea rax, [rel str_type]
    cmp rdx, rax
    jne .mc_bad_element

    ; Call subject's tp_getattr(subject, name)
    mov rdi, [rbp - MC_SUBJ]
    cmp qword [rbp - MC_SUBJ_TAG], TAG_SMALLINT
    je .mc_fail                     ; SmallInt has no attrs
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_getattr]
    test rax, rax
    jz .mc_fail
    call rax
    V_UNPACK rax, rdx           ; tp_getattr returns a Value
    test edx, edx
    jz .mc_fail                     ; attr not found

    ; Store in result tuple[i] (already owns a ref from tp_getattr, fat: *16)
    ; rdx = tag from tp_getattr (save before clobbering)
    mov r9, rdx                     ; save tag
    mov rcx, [rbp - MC_IDX]
    mov rdx, [rbp - MC_RESULT]
    mov r8, [rdx + PyTupleObject.ob_item]        ; payloads
    V_PACK rax, r9
    mov [r8 + rcx * 8], rax

    inc qword [rbp - MC_IDX]
    jmp .mc_pos_loop

.mc_kw_start:
    ;; --- Keyword loop: j=0..nkw-1 ---
    mov qword [rbp - MC_IDX], 0
.mc_kw_loop:
    mov rcx, [rbp - MC_IDX]
    mov rax, [rbp - MC_KWATTRS]
    cmp rcx, [rax + PyTupleObject.ob_size]
    jge .mc_success

    ; Get attr name from kw_attrs[j]
    mov r8, [rax + PyTupleObject.ob_item]        ; payloads
    mov rsi, [r8 + rcx*8]                        ; name string

    ; Call subject's tp_getattr(subject, name)
    mov rdi, [rbp - MC_SUBJ]
    cmp qword [rbp - MC_SUBJ_TAG], TAG_SMALLINT
    je .mc_fail                     ; SmallInt has no attrs
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_getattr]
    test rax, rax
    jz .mc_fail
    call rax
    V_UNPACK rax, rdx           ; tp_getattr returns a Value
    test edx, edx
    jz .mc_fail                     ; attr not found

    ; Store in result tuple[npos + j] (fat: *16)
    ; rdx = tag from tp_getattr (save before clobbering)
    mov r9, rdx                     ; save tag
    mov rcx, [rbp - MC_IDX]
    add rcx, [rbp - MC_NPOS]
    mov rdx, [rbp - MC_RESULT]
    mov r8, [rdx + PyTupleObject.ob_item]        ; payloads
    V_PACK rax, r9
    mov [r8 + rcx * 8], rax

    inc qword [rbp - MC_IDX]
    jmp .mc_kw_loop

.mc_success:
    ; Push result tuple, DECREF inputs
    mov rax, [rbp - MC_RESULT]
    push rax                        ; save result

    ; DECREF __match_args__ if held
    mov rdi, [rbp - MC_MATCHARGS]
    test rdi, rdi
    jz .mc_success_decref_inputs
    call obj_decref

.mc_success_decref_inputs:
    ; DECREF subject (tag-aware, may be SmallInt)
    mov rdi, [rbp - MC_SUBJ]
    mov rsi, [rbp - MC_SUBJ_TAG]
    DECREF_VAL rdi, rsi
    ; DECREF class
    mov rdi, [rbp - MC_CLASS]
    DECREF_REG rdi
    ; DECREF kw_attrs tuple
    mov rdi, [rbp - MC_KWATTRS]
    DECREF_REG rdi

    pop rax                         ; restore result tuple
    VPUSH_PTR rax
    leave
    DISPATCH

.mc_fail:
    ; DECREF partial result tuple if allocated (tuple_new zeros items,
    ; tuple_dealloc skips NULLs, so partial is safe)
    mov rdi, [rbp - MC_RESULT]
    test rdi, rdi
    jz .mc_fail_matchargs
    call obj_decref

.mc_fail_matchargs:
    ; XDECREF __match_args__ if held
    mov rdi, [rbp - MC_MATCHARGS]
    test rdi, rdi
    jz .mc_fail_decref_inputs
    call obj_decref

.mc_fail_decref_inputs:
    ; DECREF subject (tag-aware, may be SmallInt)
    mov rdi, [rbp - MC_SUBJ]
    mov rsi, [rbp - MC_SUBJ_TAG]
    DECREF_VAL rdi, rsi
    ; DECREF class
    mov rdi, [rbp - MC_CLASS]
    DECREF_REG rdi
    ; DECREF kw_attrs tuple
    mov rdi, [rbp - MC_KWATTRS]
    DECREF_REG rdi

    ; Push None
    lea rax, [rel none_singleton]
    INCREF rax
    VPUSH_PTR rax
    leave
    DISPATCH

.mc_matchargs_not_tuple:
    ; Its TYPE outlives the release below, so that is what is kept; the class
    ; name goes into the template first, because the class itself is
    ; released too.
    mov rdi, [rbp - MC_BADVAL]
    mov rsi, [rbp - MC_BADTAG]
    V_PACK rdi, rsi
    extern value_type
    call value_type
    mov [rbp - MC_BADTYPE], rax
    call .mc_class_prefix
    mov rdi, rax
    CSTRING rsi, `.__match_args__ must be a tuple (got \x01)`
    call .mc_append
    jmp .mc_raise_composed

.mc_bad_element:
    ; rsi = the element.  No class name in this one; CPython's wording names
    ; only the element's type.
    mov rdi, rsi
    call value_type
    mov [rbp - MC_BADTYPE], rax
    lea rdi, [rbp - MC_BUF]
    mov byte [rdi], 0
    CSTRING rsi, `__match_args__ elements must be strings (got \x01)`
    call .mc_append
    jmp .mc_raise_composed

.mc_raise_composed:
    call .mc_release_all
    lea rdi, [rbp - MC_BUF]
    mov rsi, [rbp - MC_BADTYPE]
    extern raise_type_error_with_typename
    call raise_type_error_with_typename

.mc_too_few:
    ; "<Class>() accepts N positional sub-patterns (M given)".  Two counts
    ; and a name, so the whole message is composed rather than templated.
    ; Reached both when __match_args__ is shorter than the sub-patterns and
    ; when there is none at all -- CPython raises in both, where this used to
    ; report no match, so `case C(x):` against a class with no __match_args__
    ; silently fell through to the next case.
    call .mc_class_prefix
    mov rdi, rax
    CSTRING rsi, "() accepts "
    call .mc_append
    mov rdi, rax
    mov rsi, [rbp - MC_MATCHARGS]
    xor edx, edx
    test rsi, rsi
    jz .mc_few_have_len
    mov rdx, [rsi + PyTupleObject.ob_size]
.mc_few_have_len:
    mov [rbp - MC_BADVAL], rdx      ; the count, across msg_append_i64
    mov rsi, rdx
    extern msg_append_i64
    call msg_append_i64
    mov rdx, [rbp - MC_BADVAL]      ; how many it accepts, for the plural
    mov rdi, rax
    cmp rdx, 1
    je .mc_few_singular
    CSTRING rsi, " positional sub-patterns ("
    jmp .mc_few_count
.mc_few_singular:
    CSTRING rsi, " positional sub-pattern ("
.mc_few_count:
    call .mc_append
    mov rdi, rax
    mov rsi, [rbp - MC_NPOS]
    call msg_append_i64
    mov rdi, rax
    CSTRING rsi, " given)"
    call .mc_append
    call .mc_release_all
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rbp - MC_BUF]
    extern exc_TypeError_type
    extern raise_exception
    call raise_exception

;; Writes the matched class's name into MC_BUF and answers the NUL after it.
;; A class with no name leaves the buffer empty, which is the wording without
;; the prefix.
.mc_class_prefix:
    lea rax, [rbp - MC_BUF]
    mov byte [rax], 0
    mov rdx, [rbp - MC_CLASS]
    test rdx, rdx
    jz .mcp_done
    mov rsi, [rdx + PyTypeObject.tp_name]
    test rsi, rsi
    jz .mcp_done
    lea rdi, [rbp - MC_BUF]
    jmp .mc_append
.mcp_done:
    ret

;; .mc_append(rdi = where to write, rsi = a C string) -> rax = the NUL
;; Bounded by the end of MC_BUF; rbt_append_cstr caps at eighty characters,
;; which would cut these messages in half.
.mc_append:
    lea rcx, [rbp - MC_BUF]
    add rcx, MC_BUFLEN - 1
    mov rax, rdi
.mca_loop:
    cmp rax, rcx
    jae .mca_done
    mov dl, [rsi]
    test dl, dl
    jz .mca_done
    mov [rax], dl
    inc rax
    inc rsi
    jmp .mca_loop
.mca_done:
    mov byte [rax], 0
    ret

;; Everything this frame owns, released.  A RAISE abandons the frame, so what
;; is not released here is leaked.
.mc_release_all:
    ; The unwinder cleans the value stack down from PyFrame.disp_sp, which
    ; DISPATCH set BEFORE this handler popped its three inputs -- so without
    ; this it releases them a second time, and the double free surfaced as a
    ; segfault in the NEXT match, reading ob_type off a class the allocator
    ; had handed out again.  op_call's .propagate_exc republishes for exactly
    ; this reason and says so.  Removing this line makes valgrind report a
    ; use-after-free of the subject, which is how it was confirmed.
    PUBLISH_SP
    mov rdi, [rbp - MC_RESULT]
    test rdi, rdi
    jz .mra_no_result
    mov qword [rbp - MC_RESULT], 0
    call obj_decref
.mra_no_result:
    mov rdi, [rbp - MC_MATCHARGS]
    test rdi, rdi
    jz .mra_no_args
    mov qword [rbp - MC_MATCHARGS], 0
    call obj_decref
.mra_no_args:
    mov rdi, [rbp - MC_SUBJ]
    mov rsi, [rbp - MC_SUBJ_TAG]
    DECREF_VAL rdi, rsi
    mov rdi, [rbp - MC_CLASS]
    DECREF_REG rdi
    mov rdi, [rbp - MC_KWATTRS]
    DECREF_REG rdi
    ret

section .rodata
.mc_matchargs_cstr: db "__match_args__", 0
section .text

END_FUNC op_match_class

;; ============================================================================
;; op_call_intrinsic_2 - Call 2-arg intrinsic function
;;
;; Opcode 174: CALL_INTRINSIC_2
;; arg selects the intrinsic.
;; TOS = arg2, TOS1 = arg1
;; Key intrinsics:
;;   1 = INTRINSIC_PREP_RERAISE - set __traceback__
;;   2 = INTRINSIC_TYPEVAR_WITH_BOUND
;;   3 = INTRINSIC_TYPEVAR_WITH_CONSTRAINTS
;;   4 = INTRINSIC_SET_FUNCTION_TYPE_PARAMS
;; ============================================================================
DEF_FUNC_BARE op_call_intrinsic_2
    cmp ecx, 1
    je .ci2_prep_reraise

    ; PEP 695: 2 = TYPEVAR_WITH_BOUND, 3 = TYPEVAR_WITH_CONSTRAINTS,
    ; 4 = SET_FUNCTION_TYPE_PARAMS.  Both operands go through.
    cmp ecx, 2
    je .ci2_typevar_bound
    cmp ecx, 3
    je .ci2_typevar_constraints
    cmp ecx, 4
    je .ci2_set_type_params

    CSTRING rdi, "CALL_INTRINSIC_2 selector"
    mov esi, ecx
    jmp ci_unsupported

.ci2_typevar_bound:
    CSTRING rdi, "_typevar_with_bound"
    jmp .ci2_typing_two
.ci2_typevar_constraints:
    CSTRING rdi, "_typevar_with_constraints"
    jmp .ci2_typing_two
.ci2_set_type_params:
    CSTRING rdi, "_set_function_type_params"
.ci2_typing_two:
    VPOP rdx                    ; TOS  = the second argument
    VPOP rsi                    ; TOS1 = the first
    push rsi
    push rdx
    call typing_call
    pop rdx
    pop rsi
    test rax, rax
    jz .ci2_typing_failed
    push rax
    mov rdi, rsi
    DECREF_V rdi, rcx
    mov rdi, [rsp]
    pop rax
    push rax
    mov rdi, rdx
    DECREF_V rdi, rcx
    pop rax
    VPUSH rax
    DISPATCH
.ci2_typing_failed:
    mov rdi, rsi
    DECREF_V rdi, rcx
    mov rdi, rdx
    DECREF_V rdi, rcx
    jmp eval_exception_unwind

.ci2_prep_reraise:
    ; INTRINSIC_PREP_RERAISE_STAR: TOS = exc_list, TOS1 = orig_exc
    ; Delegate to prep_reraise_star(orig, excs_list)
    VPOP_VAL rsi, rdx              ; rsi = exc_list
    VPOP_VAL rdi, rcx              ; rdi = orig_exc
    call prep_reraise_star
    VPUSH_PTR rax
    DISPATCH
END_FUNC op_call_intrinsic_2

;; ============================================================================
;; typing_call(rdi = a function name in _typing, rsi = a Value, rdx = a second
;;             Value or 0 for a one-argument call)
;;   -> rax = the result as a Value, or 0 with an exception pending
;;
;; PEP 695's intrinsics build TypeVar, ParamSpec, TypeVarTuple and
;; TypeAliasType objects.  None of them needs to be assembly -- they are small
;; objects with a repr, a few read-only attributes, and a value that is not
;; evaluated until it is read -- so they are `lib/_typing.py`, and this is how
;; the bytecode reaches it.  The split is _iocore/_io's and _socketcore/
;; _socket's; the bridge is codec_via_python's, down to parking
;; kw_names_pending across an import that runs whole module bodies.
;;
;; The module object is cached rather than each function: there are seven
;; entry points, and a dict lookup per intrinsic is cheaper than seven cached
;; pointers to keep in step.
;; ============================================================================
TYC_NAME  equ 8
TYC_A     equ 16
TYC_B     equ 24
TYC_FN    equ 32
TYC_ARGS  equ 56            ; two Values, the tp_call argument array
TYC_FRAME equ 72            ; + 1 push = 80, 16-aligned
DEF_FUNC_LOCAL typing_call, TYC_FRAME
    push rbx
    mov [rbp - TYC_NAME], rdi
    mov [rbp - TYC_A], rsi
    mov [rbp - TYC_B], rdx

    mov rbx, [rel typing_module]
    test rbx, rbx
    jnz .tyc_have_module

    mov rax, [gs:ThreadState.kw_names_pending]
    push rax
    mov qword [gs:ThreadState.kw_names_pending], 0

    CSTRING rdi, "_typing"
    extern str_from_cstr_heap
    call str_from_cstr_heap
    push rax
    mov rdi, rax
    xor esi, esi
    xor edx, edx
    extern import_module
    call import_module
    mov rbx, rax
    pop rdi
    extern obj_decref
    call obj_decref

    pop rax
    mov [gs:ThreadState.kw_names_pending], rax
    test rbx, rbx
    jz .tyc_failed
    mov [rel typing_module], rbx        ; the reference the module table holds

.tyc_have_module:
    mov rdi, [rbp - TYC_NAME]
    call str_from_cstr_heap
    test rax, rax
    jz .tyc_failed
    push rax
    mov rdi, [rbx + PyModuleObject.mod_dict]
    mov rsi, rax
    extern dict_get
    call dict_get
    mov [rbp - TYC_FN], rax
    pop rdi
    call obj_decref
    cmp qword [rbp - TYC_FN], 0
    je .tyc_missing

    mov rax, [rbp - TYC_A]
    mov [rbp - TYC_ARGS], rax
    mov edx, 1
    mov rax, [rbp - TYC_B]
    test rax, rax
    jz .tyc_one
    mov [rbp - TYC_ARGS + 8], rax
    mov edx, 2
.tyc_one:
    mov rdi, [rbp - TYC_FN]
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_call]
    test rax, rax
    jz .tyc_missing
    lea rsi, [rbp - TYC_ARGS]
    call rax
    pop rbx
    leave
    ret

.tyc_missing:
    RAISE exc_SystemError_type, "_typing is missing a PEP 695 constructor"
.tyc_failed:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC typing_call

section .data
; The _typing module, imported on the first PEP 695 intrinsic and kept.
typing_module: dq 0
section .text
