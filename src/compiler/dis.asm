; dis.asm - Disassemble a code object
;
; Reached with `./apython --dis "<expression>"`.  Fidelity here is semantic
; rather than byte-for-byte, so the fastest way to localise a codegen bug is to
; put this output beside `python3 -m dis` and look at where the two diverge --
; the opcode sequence should match even where the exact opargs need not.
;
; Walks the instruction stream the way the interpreter does, skipping the
; CACHE words each opcode carries, so a wrong cache count shows up here as a
; stream that decodes into nonsense rather than as a runtime mystery.

%include "macros.inc"
%include "object.inc"
%include "opcodes.inc"
%include "value.inc"
%include "compiler.inc"

extern ap_strlen
extern code_type
extern compile_source
extern obj_decref
extern str_from_cstr_heap
extern opcode_names
extern op_meta
extern sys_write

; --- Named frame-layout constants ---
DS_OFF   equ 16
DS_ARG   equ 24
DS_FRAME equ 56          ; + 5 pushes = 96

section .text

;; ============================================================================
;; dis_puts(const char *s)
;; ============================================================================
DEF_FUNC dis_puts, 8
    push rbx
    mov rbx, rdi
    call ap_strlen
    mov rdx, rax
    mov edi, 1
    mov rsi, rbx
    call sys_write
    pop rbx
    leave
    ret
END_FUNC dis_puts

;; ============================================================================
;; dis_num(int64_t v, int width)
;; Right-aligned decimal, so the columns line up with CPython's dis output.
;; ============================================================================
DN_END   equ 8           ; one past the digits; they are written backwards
DN_FRAME equ 40          ; + 1 push = 48
DEF_FUNC dis_num, DN_FRAME
    push rbx
    mov rbx, rsi                        ; width
    lea rsi, [rbp - DN_END]
    mov byte [rsi], ' '
    mov rax, rdi
    mov ecx, 10
    xor r8d, r8d
    test rax, rax
    jns .digits
    neg rax
    mov r8d, 1
.digits:
    dec rsi
    xor edx, edx
    div rcx
    add dl, '0'
    mov [rsi], dl
    test rax, rax
    jnz .digits
    test r8d, r8d
    jz .pad
    dec rsi
    mov byte [rsi], '-'
.pad:
    ; Pad out to the width the caller asked for.  It was counted into rbx and
    ; then never read -- .padloop compared against a hard-coded 12 -- so every
    ; column came out the same width whatever was requested, and nothing lined
    ; up beside `python3 -m dis`, which is the only reason this tool exists.
    lea rdx, [rbp - DN_END]
    sub rdx, rsi                        ; digits, sign included
.padloop:
    cmp rdx, rbx
    jae .emit
    dec rsi
    mov byte [rsi], ' '
    inc rdx
    jmp .padloop
.emit:
    lea rdx, [rbp - DN_END + 1]
    sub rdx, rsi                        ; add the trailing space back
    mov edi, 1
    call sys_write
    pop rbx
    leave
    ret
END_FUNC dis_num

;; ============================================================================
;; code_disassemble(PyCodeObject *code)
;;
;; rbx = code, r12 = byte offset, r13 = length, r14 = co_code base,
;; r15 = accumulated EXTENDED_ARG value.
;; ============================================================================
DEF_FUNC code_disassemble, DS_FRAME
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    lea r14, [rbx + PyCodeObject.co_code]
    mov r13d, [rbx + PyCodeObject.co_code_len]
    xor r12d, r12d
    xor r15d, r15d

.loop:
    cmp r12, r13
    jae .done

    mov rdi, r12
    shr rdi, 1                          ; report offsets in code units
    mov esi, 4
    call dis_num
    CSTRING rdi, "  "
    call dis_puts

    movzx eax, byte [r14 + r12]
    movzx edx, byte [r14 + r12 + 1]
    mov [rbp - DS_ARG], rdx
    mov [rbp - DS_OFF], rax

    lea rcx, [rel opcode_names]
    mov rdi, [rcx + rax*8]
    call dis_puts

    ; EXTENDED_ARG accumulates into the next instruction's oparg.
    mov rax, [rbp - DS_OFF]
    cmp eax, OP_EXTENDED_ARG
    jne .real_op
    shl r15, 8
    or r15, [rbp - DS_ARG]
    CSTRING rdi, `\n`
    call dis_puts
    add r12, 2
    jmp .loop

.real_op:
    ; Only opcodes that take one print an argument.
    lea rcx, [rel op_meta]
    mov rax, [rbp - DS_OFF]
    shl rax, 2
    movzx edx, byte [rcx + rax + OpMeta.flags]
    test dl, OM_HASARG
    jz .no_arg
    shl r15, 8
    or r15, [rbp - DS_ARG]
    mov rdi, r15
    mov esi, 6
    call dis_num
.no_arg:
    xor r15d, r15d
    CSTRING rdi, `\n`
    call dis_puts

    ; Step over the instruction and the CACHE words it carries.
    add r12, 2
    lea rcx, [rel op_meta]
    mov rax, [rbp - DS_OFF]
    shl rax, 2
    movzx eax, byte [rcx + rax + OpMeta.cache]
    lea r12, [r12 + rax*2]
    jmp .loop

.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC code_disassemble

;; ============================================================================
;; dis_main(const char *expr) -> rax = exit status
;; Compiles one expression and prints its bytecode.
;; ============================================================================
DEF_FUNC dis_main, 16           ; + 2 pushes = 32
    push rbx
    push r12
    mov rbx, rdi
    call ap_strlen
    mov r12, rax
    lea rdi, [rel dis_filename]
    call str_from_cstr_heap
    push rax
    mov rdi, rbx
    mov rsi, r12
    mov rdx, rax
    mov ecx, [rel dis_mode]
    call compile_source
    mov rbx, rax
    pop rdi
    call obj_decref
    test rbx, rbx
    jz .failed
    mov rdi, rbx
    call code_dump_all
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
.failed:
    CSTRING rdi, `--dis: could not compile that expression\n`
    call dis_puts
    mov eax, 1
    pop r12
    pop rbx
    leave
    ret
END_FUNC dis_main

section .rodata
dis_filename: db "<dis>", 0

section .data
align 8
global dis_mode
dis_mode: dq CMODE_EVAL

section .text

;; ============================================================================
;; code_dump_exctab(PyCodeObject *code)
;; Decode co_exceptiontable the way exc_table_find_handler does and print it.
;; A table that reads back wrong here is the fastest signal that the encoder
;; and the decoder disagree.
;; ============================================================================
DX_POS   equ 16
DX_LEN   equ 24
DX_DATA  equ 32
DX_FRAME equ 40           ; + 3 pushes = 64
DEF_FUNC code_dump_exctab, DX_FRAME
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov rax, [rbx + PyCodeObject.co_exceptiontable]
    test rax, rax
    jz .none
    mov r13, [rax + PyBytesObject.ob_size]
    test r13, r13
    jz .none
    lea r12, [rax + PyBytesObject.data]
    mov [rbp - DX_DATA], r12
    mov [rbp - DX_LEN], r13
    mov qword [rbp - DX_POS], 0
    CSTRING rdi, `exceptiontable:\n`
    call dis_puts
.entry:
    mov rax, [rbp - DX_POS]
    cmp rax, [rbp - DX_LEN]
    jae .done
    CSTRING rdi, "  "
    call dis_puts
    call .varint
    mov rdi, rax
    mov esi, 4
    call dis_num
    CSTRING rdi, " size "
    call dis_puts
    call .varint
    mov rdi, rax
    mov esi, 4
    call dis_num
    CSTRING rdi, " -> "
    call dis_puts
    call .varint
    mov rdi, rax
    mov esi, 4
    call dis_num
    CSTRING rdi, " depth_lasti "
    call dis_puts
    call .varint
    mov rdi, rax
    mov esi, 4
    call dis_num
    CSTRING rdi, `\n`
    call dis_puts
    jmp .entry
.none:
    CSTRING rdi, `exceptiontable: (empty)\n`
    call dis_puts
.done:
    pop r13
    pop r12
    pop rbx
    leave
    ret

    jmp .real_done

; Local: the same MSB-first 6-bit decode exc_table_find_handler performs.
.varint:
    sub rsp, 8
    mov r12, [rbp - DX_DATA]
    mov rcx, [rbp - DX_POS]
    movzx edx, byte [r12 + rcx]
    inc rcx
    mov [rbp - DX_POS], rcx
    mov eax, edx
    and eax, 0x3f
.vloop:
    test edx, 0x40
    jz .vdone
    mov rcx, [rbp - DX_POS]
    cmp rcx, [rbp - DX_LEN]
    jae .vdone
    shl eax, 6
    movzx edx, byte [r12 + rcx]
    inc rcx
    mov [rbp - DX_POS], rcx
    mov ecx, edx
    and ecx, 0x3f
    or eax, ecx
    jmp .vloop
.vdone:
    add rsp, 8
    ret

.real_done:
END_FUNC code_dump_exctab

section .text

;; ============================================================================
;; code_dump_all(PyCodeObject *code)
;; The code object and everything nested in its constants.  A compiler bug in a
;; method or a comprehension is invisible from the module's own bytecode, so
;; the recursion is the point.
;; ============================================================================
DA_I     equ 16
DA_FRAME equ 32           ; + 2 pushes = 40
DEF_FUNC code_dump_all, DA_FRAME
    push rbx
    push r12
    mov rbx, rdi
    mov rdi, rbx
    call code_disassemble
    mov rdi, rbx
    call code_dump_exctab

    mov r12, [rbx + PyCodeObject.co_consts]
    test r12, r12
    jz .done
    mov qword [rbp - DA_I], 0
.loop:
    mov rax, [rbp - DA_I]
    cmp rax, [r12 + PyVarObject.ob_size]
    jae .done
    mov rdx, [r12 + PyTupleObject.ob_item]
    mov rcx, [rbp - DA_I]
    mov rax, [rdx + rcx*8]
    ; Only a pointer can be a code object; an immediate int or float is not.
    V_TEST_PTR rax, r8
    ja .next
    test rax, rax
    jz .next
    mov rdx, [rax + PyObject.ob_type]
    lea rcx, [rel code_type]
    cmp rdx, rcx
    jne .next
    push rax
    CSTRING rdi, `--- nested code object\n`
    call dis_puts
    pop rdi
    call code_dump_all
.next:
    inc qword [rbp - DA_I]
    jmp .loop
.done:
    pop r12
    pop rbx
    leave
    ret
END_FUNC code_dump_all

ASM_INIT
