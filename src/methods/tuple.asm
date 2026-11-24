; methods/tuple.asm - tuple methods
;
; tuple's dunders and its two public methods.  They lived in methods/list.asm,
; which made that the largest file in the directory and left tuple as the one
; builtin type whose methods did not sit beside its own name -- the pairing
; CLAUDE.md describes, where methods/X.asm is X's methods and pyo/X.asm is X
; itself.

%include "macros.inc"
%include "object.inc"
extern obj_as_slice_index

extern tuple_type
extern tuple_new
extern obj_incref
extern obj_decref
extern bool_false

extern bool_true


extern exc_ValueError_type

extern int_from_i64

extern int_to_i64

extern obj_richcompare_bool

extern set_exception

extern tuple_concat

extern tuple_contains

extern tuple_repeat
extern set_seq_repeat_not_index

extern tuple_subscript

section .text

DEF_FUNC_BARE tuple_dunder_getitem
    REQUIRE_SELF_BARE tuple_type, "__getitem__"
    mov rax, [rdi]          ; self
    mov rsi, [rdi + 8]      ; the key Value
    mov rdi, rax
    jmp tuple_subscript
END_FUNC tuple_dunder_getitem

DEF_FUNC tuple_dunder_contains
    REQUIRE_SELF tuple_type, "__contains__"
    mov rax, [rdi]          ; self
    mov rsi, [rdi + 8]      ; the item Value
    mov rdi, rax
    call tuple_contains
    test eax, eax
    jz .tdc_false
    lea rax, [rel bool_true]
    jmp .tdc_done
.tdc_false:
    lea rax, [rel bool_false]
.tdc_done:
    mov edx, TAG_PTR
    INCREF rax
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC tuple_dunder_contains

DEF_FUNC tuple_dunder_len
    REQUIRE_SELF tuple_type, "__len__"
    mov rax, [rdi]          ; self
    mov rdi, [rax + PyTupleObject.ob_size]
    call int_from_i64
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC tuple_dunder_len

DEF_FUNC_BARE tuple_dunder_add
    REQUIRE_SELF_BARE tuple_type, "__add__"
    mov rax, [rdi]
    mov rsi, [rdi + 8]
    mov rdi, rax
    jmp tuple_concat
END_FUNC tuple_dunder_add

;; tuple_repeat DECLINES a count that is not an index -- it answers a NULL
;; Value, so that `(1,) * R()` can still reach R.__rmul__ -- and a tail jump
;; would have handed that NULL back as the dunder's own answer: `x = (1,)
;; .__mul__("x")` raised nothing and bound nothing, and the NameError came
;; from the next line.  Both call, and turn the decline into the refusal
;; CPython's wrapper gives.
DEF_FUNC_BARE tuple_dunder_mul
    REQUIRE_SELF_BARE tuple_type, "__mul__"
    mov rax, [rdi]
    mov rsi, [rdi + 8]
    mov rdi, rax
    push rsi                    ; one push: rsp is 16-aligned at the call
    call tuple_repeat
    pop rsi
    test rax, rax
    jz set_seq_repeat_not_index ; a tail call: its 0 is this dunder's own
    ret
END_FUNC tuple_dunder_mul

;; __rmul__ has the operands the other way round, and tuple_repeat wants the
;; sequence first.
DEF_FUNC_BARE tuple_dunder_rmul
    REQUIRE_SELF_BARE tuple_type, "__rmul__"
    mov rax, [rdi]
    mov rsi, [rdi + 8]
    mov rdi, rax
    push rsi
    call tuple_repeat
    pop rsi
    test rax, rax
    jz set_seq_repeat_not_index ; a tail call: its 0 is this dunder's own
    ret
END_FUNC tuple_dunder_rmul

;; ============================================================================
;; tuple_method_index(args, nargs) -> SmallInt index
;; Fails: 0
;; args[0]=self (tuple), args[1]=value, optional args[2]=start, args[3]=stop
;; ============================================================================
TMI_ARGS  equ 8
TMI_NARGS equ 16
DEF_FUNC tuple_method_index, 16
    push rbx
    push r12
    push r13
    push r14

    mov [rbp - TMI_ARGS], rdi      ; save args
    mov [rbp - TMI_NARGS], rsi     ; save nargs
    mov rbx, [rdi]          ; self (tuple)
    mov r12, [rdi + 8]      ; the value to find, as a Value
    mov r13, [rbx + PyTupleObject.ob_size]  ; default stop = size

    xor ecx, ecx            ; default start = 0

    ; Check for optional start arg (nargs >= 3)
    cmp qword [rbp - TMI_NARGS], 3
    jl .ti_have_bounds
    mov rax, [rbp - TMI_ARGS]
    push rcx
    mov rdi, [rax + 16]      ; args[2] payload
    V_UNPACK rdi, rdx       ; args[2]
    call obj_as_slice_index
    ERR_M1 .tindex_error_pop
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
    cmp qword [rbp - TMI_NARGS], 4
    jl .ti_have_bounds
    mov rax, [rbp - TMI_ARGS]
    push rcx
    mov rdi, [rax + 24]      ; args[3] payload
    V_UNPACK rdi, rdx       ; args[3]
    call obj_as_slice_index
    ERR_M1 .tindex_error_pop
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
    mov r14, rcx                ; r14 = the search index, live across the call

.tindex_loop:
    cmp r14, r13
    jge .tindex_not_found

    mov rsi, [rbx + PyTupleObject.ob_item]
    mov rdi, [rsi + r14 * 8]    ; the element Value

    ; This was a hand-rolled chain -- identity, then SmallInt, then strcmp --
    ; which is most of PyObject_RichCompareBool with the interesting parts
    ; missing: no element __eq__, no reflected call, and a raise reported as
    ; "no match".
    mov rsi, r12
    mov edx, PY_EQ
    call obj_richcompare_bool
    cmp eax, -1
    je .tindex_error
    test eax, eax
    jnz .tindex_found

    inc r14
    jmp .tindex_loop

.tindex_found:
    mov rdi, r14
    call int_from_i64
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.tindex_not_found:
    SET_EXC exc_ValueError_type, "tuple.index(x): x not in tuple"
    jmp .tindex_error
.tindex_error_pop:
    add rsp, 8                  ; the start, parked across the conversion
.tindex_error:
    xor eax, eax
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC tuple_method_index

;; ============================================================================
;; tuple_method_count(args, nargs) -> SmallInt
;; Fails: 0
;; args[0]=self (tuple), args[1]=value
;; ============================================================================
TCT_IDX   equ 8
TCT_COUNT equ 16
TCT_FRAME equ 24            ; + 3 pushes = 48, 16-aligned
DEF_FUNC tuple_method_count, TCT_FRAME
    push rbx
    push r12
    push r13

    mov rbx, [rdi]          ; self (tuple)
    mov r12, [rdi + 8]      ; the value Value
    mov r13, [rbx + PyTupleObject.ob_size]
    mov qword [rbp - TCT_IDX], 0
    mov qword [rbp - TCT_COUNT], 0

.tcount_loop:
    mov rcx, [rbp - TCT_IDX]
    cmp rcx, r13
    jge .tcount_done

    mov rax, [rbx + PyTupleObject.ob_item]
    mov rdi, [rax + rcx * 8]

    ; A word compare only ever matched an identical object, so an element
    ; with its own __eq__ was never counted.
    mov rsi, r12
    mov edx, PY_EQ
    call obj_richcompare_bool
    cmp eax, -1
    je .tcount_error
    test eax, eax
    jz .tcount_next
    inc qword [rbp - TCT_COUNT]

.tcount_next:
    inc qword [rbp - TCT_IDX]
    jmp .tcount_loop

.tcount_done:
    mov rdi, [rbp - TCT_COUNT]
    call int_from_i64
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.tcount_error:
    xor eax, eax
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC tuple_method_count

;; ============================================================================
;; tuple.__getnewargs__(self) -> (tuple(self),)
;;
;; An EXACT tuple hands itself over -- it is immutable, so there is nothing to
;; copy and CPython does the same -- while a subclass hands over a plain tuple,
;; because the argument is about to be given to tuple.__new__ and a subclass
;; instance is a different thing to ask for.
;; ============================================================================
global tuple_method_getnewargs
TGNA_SELF  equ 8
TGNA_INNER equ 16
TGNA_FRAME equ 40           ; + 1 push = 48, 16-aligned
DEF_FUNC tuple_method_getnewargs, TGNA_FRAME
    push rbx
    mov rbx, [rdi]                      ; args[0] = self, always a pointer
    mov rax, [rbx + PyObject.ob_type]
    lea rcx, [rel tuple_type]
    cmp rax, rcx
    jne .tgna_subclass
    mov rdi, rbx
    call obj_incref
    mov [rbp - TGNA_INNER], rbx
    jmp .tgna_wrap

.tgna_subclass:
    mov rdi, [rbx + PyTupleObject.ob_size]
    call tuple_new
    test rax, rax
    jz .tgna_failed
    mov [rbp - TGNA_INNER], rax
    mov rsi, [rbx + PyTupleObject.ob_item]
    mov rdi, [rax + PyTupleObject.ob_item]
    xor ecx, ecx
.tgna_copy:
    cmp rcx, [rbx + PyTupleObject.ob_size]
    jge .tgna_wrap
    mov rdx, [rsi + rcx * 8]
    INCREF_V rdx, rax
    mov [rdi + rcx * 8], rdx
    inc rcx
    jmp .tgna_copy

.tgna_wrap:
    mov edi, 1
    call tuple_new
    test rax, rax
    jz .tgna_drop
    mov rdx, [rax + PyTupleObject.ob_item]
    mov rcx, [rbp - TGNA_INNER]
    mov [rdx], rcx                      ; the outer tuple takes that reference
    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.tgna_drop:
    mov rdi, [rbp - TGNA_INNER]
    call obj_decref
.tgna_failed:
    xor eax, eax
    xor edx, edx
    pop rbx
    leave
    ret
END_FUNC tuple_method_getnewargs
