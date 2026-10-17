; comperr.asm - how a compile REPORTS, rather than what it compiles
;
; The compiler cannot raise.  raise_exception tail-jumps into
; eval_exception_unwind, which calls fatal_error when there is no live
; interpreter frame -- and `./apython foo.py` compiles before any frame
; exists.  So an error is RECORDED (comp_error and its two siblings write
; Comp.err, first one wins), every buffer is freed, and only then is the
; SyntaxError built and made pending.  Warnings defer the same way, for the
; same reason.
;
; What lives here: the recording side (comp_error, comp_error_span,
; comp_error_node), the message builder the messages that name something need
; (comp_msg_*), the location a SyntaxError carries (comp_attach_location and
; the source line it quotes), and the warning queue.  Split out of
; compile.asm when it reached the 100k cap that src/compiler/lint.py
; enforces; nothing changed but which file it is in.

%include "macros.inc"
%include "object.inc"
%include "value.inc"
%include "opcodes.inc"
%include "compiler.inc"

extern dict_get
extern obj_call_n
extern str_from_cstr_heap
extern ap_memcpy
extern exc_SyntaxError_type
extern exc_IndentationError_type
extern exc_TabError_type
extern tuple_new
extern obj_decref
extern str_new_heap
extern ast_at
extern ast_span_at
extern none_singleton
extern rbt_append_cstr
extern msg_append_i64
extern type_is_subtype
extern obj_incref
extern obj_dealloc
extern import_module
extern comp_set_pending

section .text

;; ============================================================================
;; comp_attach_location(Comp *c, PyExceptionObject *exc)
;; Replace the exception's args with (msg, (filename, lineno, offset, text)).
;; Best-effort: on any allocation failure the bare message is left alone.
;; ============================================================================
AL_INNER equ 24
AL_OUTER equ 32
AL_FRAME equ 56           ; + 3 pushes = 80
DEF_FUNC comp_attach_location, AL_FRAME
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi

    ; Only the syntax errors carry a position.
    mov rax, [rbx + Comp.err + CompErr.type]
    lea rcx, [rel exc_SyntaxError_type]
    cmp rax, rcx
    je .go
    lea rcx, [rel exc_IndentationError_type]
    cmp rax, rcx
    je .go
    lea rcx, [rel exc_TabError_type]
    cmp rax, rcx
    jne .done
.go:
    mov edi, 6
    call tuple_new
    test rax, rax
    jz .done
    mov [rbp - AL_INNER], rax

    mov rdx, [rax + PyTupleObject.ob_item]
    mov rcx, [rbx + Comp.filename]
    test rcx, rcx
    jnz .have_file
    lea rcx, [rel none_singleton]
.have_file:
    INCREF rcx
    mov [rdx], rcx

    mov rsi, [rbp - AL_INNER]
    mov rsi, [rsi + PyTupleObject.ob_item]
    mov ecx, [rbx + Comp.err + CompErr.lineno]
    V_PACK_I64 rcx, rdx
    mov [rsi + 8], rcx
    ; CPython's offset is one-based; the column recorded here is not -- and it
    ; is a signed int32, so it has to be sign-extended.  Zero-extending a
    ; negative one made the offset 4294967285, and the caret loop that renders
    ; it writes one space per column.
    movsxd rcx, dword [rbx + Comp.err + CompErr.col]
    test rcx, rcx
    jns .col_ok
    xor ecx, ecx
.col_ok:
    inc rcx
    V_PACK_I64 rcx, rdx
    mov [rsi + 16], rcx

    mov rdi, rbx
    mov esi, [rbx + Comp.err + CompErr.lineno]
    call comp_line_text
    test rax, rax
    jnz .have_text
    ; A slot in a tuple must hold a real Value: None, not NULL.  A NULL there
    ; is not an empty string, it is a hole that anything reading the tuple
    ; walks straight into.
    lea rax, [rel none_singleton]
    INCREF rax
.have_text:
    mov rdx, [rbp - AL_INNER]
    mov rdx, [rdx + PyTupleObject.ob_item]
    mov [rdx + 24], rax

    ; CPython's tuple has six fields; the last two are the end of the span,
    ; and its offset is one-based like the first one.
    mov ecx, [rbx + Comp.err + CompErr.end_lineno]
    V_PACK_I64 rcx, rsi
    mov [rdx + 32], rcx
    ; end_col is NOT clamped the way col is.  CPython's own end_offset is 0
    ; for every "was never closed" and -1 for "expected 'except' or 'finally'
    ; block", and a program that reads e.end_offset should see what CPython's
    ; would give it.  Nothing draws a caret from this one -- tb_write_carets
    ; and the syntax-error header both work from the offset -- so a negative
    ; here cannot become four billion spaces the way a negative col could.
    movsxd rcx, dword [rbx + Comp.err + CompErr.end_col]
    inc rcx
    V_PACK_I64 rcx, rsi
    mov [rdx + 40], rcx

    mov edi, 2
    call tuple_new
    test rax, rax
    jz .free_inner
    mov [rbp - AL_OUTER], rax
    mov rdx, [rax + PyTupleObject.ob_item]

    ; args[0] is the message the exception already carries.
    mov rcx, [r12 + PyExceptionObject.exc_args]
    test rcx, rcx
    jz .no_msg
    cmp qword [rcx + PyTupleObject.ob_size], 0
    jle .no_msg
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov rcx, [rcx]
    INCREF_V rcx, r8
    mov [rdx], rcx
    jmp .have_msg
.no_msg:
    mov qword [rdx], 0
.have_msg:
    mov rcx, [rbp - AL_INNER]
    mov [rdx + 8], rcx

    mov rdi, [r12 + PyExceptionObject.exc_args]
    mov rax, [rbp - AL_OUTER]
    mov [r12 + PyExceptionObject.exc_args], rax
    test rdi, rdi
    jz .done
    call obj_decref
    jmp .done

.free_inner:
    mov rdi, [rbp - AL_INNER]
    call obj_decref
.done:
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC comp_attach_location

;; ============================================================================
;; comp_line_text(Comp *c, int lineno) -> PyStrObject*, or 0
;; The source of one line, newline included, as CPython's SyntaxError.text is.
;; ============================================================================
LT_LINE  equ 16
LT_START equ 32
LT_FRAME equ 40           ; + 1 push = 48
DEF_FUNC comp_line_text, LT_FRAME
    push rbx
    mov rbx, rdi
    mov [rbp - LT_LINE], rsi
    cmp rsi, 1
    jl .none
    mov rax, [rbx + Comp.src]
    test rax, rax
    jz .none

    ; Walk to the start of the wanted line.
    xor ecx, ecx                        ; byte position
    mov edx, 1                          ; current line number
.scan:
    cmp rdx, [rbp - LT_LINE]
    jae .found
    cmp rcx, [rbx + Comp.srclen]
    jae .none
    cmp byte [rax + rcx], 10
    jne .scan_next
    inc rdx
.scan_next:
    inc rcx
    jmp .scan
.found:
    mov [rbp - LT_START], rcx
    ; And to its end, keeping the newline the way CPython does.
.end_scan:
    cmp rcx, [rbx + Comp.srclen]
    jae .have_end
    inc rcx
    cmp byte [rax + rcx - 1], 10
    jne .end_scan
.have_end:
    mov rdx, rcx
    sub rdx, [rbp - LT_START]
    jz .none
    add rax, [rbp - LT_START]
    mov rdi, rax
    mov rsi, rdx
    call str_new_heap
    pop rbx
    leave
    ret
.none:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC comp_line_text

;; ============================================================================
;; (was compiler/comperr.asm)
;; ============================================================================

section .text

section .text

;; ============================================================================
;; comp_msg_start() -> rax = the message buffer, empty
;; comp_msg_cstr(rdi = a position in it, rsi = text) -> rax = the new position
;; comp_msg_i64(rdi = a position in it, rsi = a number) -> rax = likewise
;;
;; Some of CPython's syntax errors name something the source decides: the line
;; a string literal was detected on, the digit that is wrong for a base, the
;; statement an indented block was expected after.  CompErr.msg is a borrowed
;; `const char *`, so those need storage that outlives the compile -- and one
;; static buffer is enough, because the FIRST error wins and is consumed once,
;; by comp_set_pending, before the compiler is entered again.
;; ============================================================================
;; ============================================================================
;; comp_msg_start() -> rax = the message buffer, emptied
;; ============================================================================
DEF_FUNC_BARE comp_msg_start
    lea rax, [rel comp_msgbuf]
    mov byte [rax], 0
    ret
END_FUNC comp_msg_start

;; ============================================================================
;; comp_msg_cstr(rdi = a position in the buffer, rsi = text) -> rax = the NUL
;; it wrote, which is where the next piece goes
;; ============================================================================
extern rbt_append_cstr
DEF_FUNC comp_msg_cstr
    call rbt_append_cstr
    leave
    ret
END_FUNC comp_msg_cstr

;; ============================================================================
;; comp_msg_i64(rdi = a position in the buffer, rsi = a number) -> rax = the
;; NUL it wrote
;; ============================================================================
extern msg_append_i64
DEF_FUNC comp_msg_i64
    call msg_append_i64
    leave
    ret
END_FUNC comp_msg_i64

;; ============================================================================
;; comp_msg_utf8(rdi = a position in the buffer, rsi = a code point)
;;   -> rax = the NUL it wrote
;;
;; The character itself, for the messages that show it: CPython says
;; `invalid character '#' (U+0023)` and the quotes want the real thing
;; between them.  A surrogate or an out-of-range value writes nothing, which
;; leaves the code point in the parentheses as the only report -- and is what
;; the non-printable wording does on purpose anyway.
;; ============================================================================
global comp_msg_utf8
DEF_FUNC_BARE comp_msg_utf8
    mov rax, rdi
    cmp esi, 0x110000
    jae .cmu_done
    mov ecx, esi
    and ecx, ~0x7ff
    cmp ecx, 0xd800
    je .cmu_done                    ; a lone surrogate is not encodable
    cmp esi, 0x80
    jb .cmu_one
    cmp esi, 0x800
    jb .cmu_two
    cmp esi, 0x10000
    jb .cmu_three
    mov ecx, esi
    shr ecx, 18
    or cl, 0xf0
    mov [rax], cl
    mov ecx, esi
    shr ecx, 12
    and cl, 0x3f
    or cl, 0x80
    mov [rax + 1], cl
    mov ecx, esi
    shr ecx, 6
    and cl, 0x3f
    or cl, 0x80
    mov [rax + 2], cl
    mov ecx, esi
    and cl, 0x3f
    or cl, 0x80
    mov [rax + 3], cl
    add rax, 4
    jmp .cmu_done
.cmu_three:
    mov ecx, esi
    shr ecx, 12
    or cl, 0xe0
    mov [rax], cl
    mov ecx, esi
    shr ecx, 6
    and cl, 0x3f
    or cl, 0x80
    mov [rax + 1], cl
    mov ecx, esi
    and cl, 0x3f
    or cl, 0x80
    mov [rax + 2], cl
    add rax, 3
    jmp .cmu_done
.cmu_two:
    mov ecx, esi
    shr ecx, 6
    or cl, 0xc0
    mov [rax], cl
    mov ecx, esi
    and cl, 0x3f
    or cl, 0x80
    mov [rax + 1], cl
    add rax, 2
    jmp .cmu_done
.cmu_one:
    mov [rax], sil
    inc rax
.cmu_done:
    mov byte [rax], 0
    ret
END_FUNC comp_msg_utf8

;; ============================================================================
;; comp_msg_ucode(rdi = a position in the buffer, rsi = a code point)
;;   -> rax = the NUL it wrote
;;
;; `U+00A0`: CPython's spelling, uppercase hex, at least four digits and more
;; when the code point needs them.
;; ============================================================================
global comp_msg_ucode
DEF_FUNC_BARE comp_msg_ucode
    mov byte [rdi], 'U'
    mov byte [rdi + 1], '+'
    add rdi, 2
    mov ecx, 20                     ; the top nibble of 0x10FFFF's six
.cmc_skip:
    cmp ecx, 12
    jle .cmc_emit
    mov eax, esi
    shr eax, cl
    and eax, 0x0f
    jnz .cmc_emit
    sub ecx, 4
    jmp .cmc_skip
.cmc_emit:
    mov eax, esi
    shr eax, cl
    and eax, 0x0f
    cmp eax, 10
    jb .cmc_digit
    add eax, 'A' - 10
    jmp .cmc_store
.cmc_digit:
    add eax, '0'
.cmc_store:
    mov [rdi], al
    inc rdi
    sub ecx, 4
    jns .cmc_emit
    mov byte [rdi], 0
    mov rax, rdi
    ret
END_FUNC comp_msg_ucode

;; ============================================================================
;; comp_msg_hex2(rdi = a position in the buffer, rsi = a byte)
;;   -> rax = the NUL it wrote
;;
;; Two lowercase hex digits, for a message that names a raw byte rather than a
;; character: `invalid non-UTF-8 byte 0xe9`.  comp_msg_ucode is the other
;; spelling, uppercase and at least four digits, for a code point.
;; ============================================================================
global comp_msg_hex2
DEF_FUNC_BARE comp_msg_hex2
    mov ecx, 4
.cmh_emit:
    mov eax, esi
    shr eax, cl
    and eax, 0x0f
    cmp eax, 10
    jb .cmh_digit
    add eax, 'a' - 10
    jmp .cmh_store
.cmh_digit:
    add eax, '0'
.cmh_store:
    mov [rdi], al
    inc rdi
    sub ecx, 4
    jns .cmh_emit
    mov byte [rdi], 0
    mov rax, rdi
    ret
END_FUNC comp_msg_hex2


section .bss
comp_msgbuf: resb 256
cew_warn_explicit: resq 1   ; warnings.warn_explicit, imported once
cpw_n:     resd 1           ; warnings recorded before the interpreter existed
cpw_pad:   resd 1
cpw_file:  resq 1           ; the filename they belong to, owned
cpw_warns: resb CompWarn_size * COMP_MAX_WARNS
section .text

;; ============================================================================
;; comp_warn(Comp *c, const char *msg, int lineno) -> nothing
;;
;; Record a SyntaxWarning for comp_emit_warnings to raise once the compile is
;; over.  Nothing here may call into Python: `./apython foo.py` compiles
;; before any frame exists, which is why the error protocol defers too.  Past
;; COMP_MAX_WARNS the rest are dropped -- CPython emits one per occurrence,
;; and a file with sixteen of these has been told.
;; ============================================================================
global comp_warn
DEF_FUNC_BARE comp_warn
    mov eax, [rdi + Comp.warn_n]
    cmp eax, COMP_MAX_WARNS
    jae .cw_full
    lea rcx, [rdi + Comp.warns]
    imul r8d, eax, CompWarn_size
    add rcx, r8
    mov [rcx + CompWarn.lineno], edx
    inc eax
    mov [rdi + Comp.warn_n], eax
    ; The text is copied, not pointed at: cg_warn_is_literal composes its
    ; message into a shared buffer that the next one would overwrite.
    xor edx, edx
.cw_copy:
    cmp edx, COMP_WARN_TEXT - 1
    jae .cw_end
    movzx eax, byte [rsi + rdx]
    mov [rcx + CompWarn.msg + rdx], al
    test al, al
    jz .cw_full
    inc edx
    jmp .cw_copy
.cw_end:
    mov byte [rcx + CompWarn.msg + rdx], 0
.cw_full:
    ret
END_FUNC comp_warn

;; ============================================================================
;; comp_emit_warnings(Comp *c) -> rax = 1, or 0 with an exception pending
;;
;; warnings.warn_explicit(msg, SyntaxWarning, filename, lineno), once per
;; recorded warning.  That entry point takes the position rather than reading
;; it off a frame, which is exactly why CPython's compiler uses it too -- and
;; it is why this can run at all here.  A filter set to "error" turns the
;; warning into a raise, and then the compile fails with it.
;;
;; The module is imported lazily and cached, as builtin_open_fn does for _io:
;; importing warnings from comp_init would run Python before main() is ready.
;; ============================================================================
CEW_C     equ 8
CEW_FN    equ 16
CEW_MOD   equ 24
CEW_ARGS  equ 64            ; four Values, ending here
CEW_FRAME equ 72            ; + 1 push = 80, 16-aligned
global comp_emit_warnings
DEF_FUNC comp_emit_warnings, CEW_FRAME
    push rbx
    mov [rbp - CEW_C], rdi
    mov ebx, [rdi + Comp.warn_n]
    test ebx, ebx
    jz .cew_none

    ; Nothing can be imported before import_init has run, and
    ; `./apython foo.py` compiles first: sys.modules is the flag for it.
    ; A warning recorded that early is held in a process-global queue and
    ; flushed by main once the interpreter is up.
    extern sys_modules_dict
    cmp qword [rel sys_modules_dict], 0
    je .cew_defer

    call cew_lookup_warn_explicit
    test rax, rax
    jz .cew_failed
.cew_have_fn:
    mov [rbp - CEW_FN], rax

    xor ebx, ebx
.cew_loop:
    mov rdi, [rbp - CEW_C]
    cmp ebx, [rdi + Comp.warn_n]
    jae .cew_none

    lea rcx, [rdi + Comp.warns]
    imul eax, ebx, CompWarn_size
    add rcx, rax
    push rcx
    lea rdi, [rcx + CompWarn.msg]
    call str_from_cstr_heap
    pop rcx
    test rax, rax
    jz .cew_failed
    mov [rbp - CEW_ARGS], rax
    extern exc_SyntaxWarning_type
    lea rax, [rel exc_SyntaxWarning_type]
    mov [rbp - CEW_ARGS + 8], rax
    mov rdi, [rbp - CEW_C]
    mov rax, [rdi + Comp.filename]
    mov [rbp - CEW_ARGS + 16], rax
    mov eax, [rcx + CompWarn.lineno]
    V_PACK_I64 rax, rdx
    mov [rbp - CEW_ARGS + 24], rax

    mov rdi, [rbp - CEW_FN]
    lea rsi, [rbp - CEW_ARGS]
    mov edx, 4
    extern obj_call_n
    call obj_call_n
    push rax
    mov rdi, [rbp - CEW_ARGS]
    extern obj_decref
    call obj_decref
    pop rax
    test rax, rax
    jz .cew_raised
    XDECREF_V rax, rcx
    inc ebx
    jmp .cew_loop

.cew_none:
    mov rdi, [rbp - CEW_C]
    mov dword [rdi + Comp.warn_n], 0
    mov eax, 1
    pop rbx
    leave
    ret

.cew_defer:
    ; Move what is recorded to the process-global queue, keeping the
    ; filename alive: the Comp is about to be freed.
    mov rdi, [rbp - CEW_C]
    call comp_defer_warnings
    jmp .cew_none

.cew_failed:
    ; The warning could not be emitted, which is not the program's fault:
    ; drop it and let the compile succeed.  Anything the import left pending
    ; goes with it.
    mov rax, [gs:ThreadState.current_exception]
    test rax, rax
    jz .cew_none
    mov qword [gs:ThreadState.current_exception], 0
    mov rdi, rax
    call obj_decref
    jmp .cew_none

.cew_raised:
    ; A filter set to "error" turned it into a raise.  CPython replaces the
    ; SyntaxWarning with a SyntaxError carrying the same text, so what the
    ; programmer sees is a compile error with a caret, not a warning class
    ; escaping from compile().
    mov rdi, [rbp - CEW_C]
    mov dword [rdi + Comp.warn_n], 0
    mov rax, [gs:ThreadState.current_exception]
    test rax, rax
    jz .cew_raised_done
    mov rdi, rax
    mov rsi, [rax + PyObject.ob_type]
    extern exc_SyntaxWarning_type
    lea rax, [rel exc_SyntaxWarning_type]
    mov rdi, rsi
    mov rsi, rax
    extern type_is_subtype
    call type_is_subtype
    test eax, eax
    jz .cew_raised_done
    mov rdi, [gs:ThreadState.current_exception]
    mov qword [gs:ThreadState.current_exception], 0
    call obj_decref
    ; The record ebx stopped at is the one that raised.
    mov rdi, [rbp - CEW_C]
    lea rcx, [rdi + Comp.warns]
    imul eax, ebx, CompWarn_size
    add rcx, rax
    lea rdx, [rcx + CompWarn.msg]
    mov ecx, [rcx + CompWarn.lineno]
    lea rsi, [rel exc_SyntaxError_type]
    xor r8d, r8d
    call comp_error
    mov rdi, [rbp - CEW_C]
    call comp_set_pending
.cew_raised_done:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC comp_emit_warnings

;; ============================================================================
;; comp_defer_warnings(Comp *c) -> nothing
;;
;; The process-global half of the channel.  `./apython foo.py` compiles
;; before import_init has run, so there is no `warnings` to call and no
;; sys.modules to find it in; what the tokenizer recorded is moved here and
;; main flushes it once the interpreter is up.  The filename is kept alive
;; because the Comp that owned it is freed on the way out.
;; ============================================================================
global comp_defer_warnings
DEF_FUNC_BARE comp_defer_warnings
    push rbx
    mov rbx, rdi
    mov ecx, [rbx + Comp.warn_n]
    test ecx, ecx
    jz .cdw_done
    cmp qword [rel cpw_file], 0
    jne .cdw_done               ; one file's worth is all this ever needs
    mov rax, [rbx + Comp.filename]
    test rax, rax
    jz .cdw_done
    mov [rel cpw_file], rax
    inc qword [rax + PyObject.ob_refcnt]
    xor edx, edx
.cdw_copy:
    cmp edx, ecx
    jae .cdw_stored
    imul r8d, edx, CompWarn_size
    lea rsi, [rbx + Comp.warns]
    add rsi, r8
    lea rdi, [rel cpw_warns]
    add rdi, r8
    push rdx
    push rcx
    mov edx, CompWarn_size
    extern ap_memcpy
    call ap_memcpy
    pop rcx
    pop rdx
    inc edx
    jmp .cdw_copy
.cdw_stored:
    mov [rel cpw_n], ecx
.cdw_done:
    pop rbx
    ret
END_FUNC comp_defer_warnings

;; ============================================================================
;; comp_flush_warnings() -> nothing
;;
;; Emit what comp_defer_warnings put aside, and forget it either way.  Called
;; from main once import_init has run, and harmless before that: the queue is
;; empty unless a compile already happened, and sys.modules says whether
;; anything can be imported yet.
;; ============================================================================
CFW_ARGS  equ 32            ; four Values, ending here
CFW_FN    equ 40
CFW_FRAME equ 56            ; + 1 push = 64, 16-aligned
global comp_flush_warnings
DEF_FUNC comp_flush_warnings, CFW_FRAME
    push rbx
    cmp dword [rel cpw_n], 0
    je .cfw_done
    cmp qword [rel sys_modules_dict], 0
    je .cfw_done

    mov rdi, [rel cpw_file]
    call cew_lookup_warn_explicit
    test rax, rax
    jz .cfw_drop
    mov [rbp - CFW_FN], rax

    xor ebx, ebx
.cfw_loop:
    cmp ebx, [rel cpw_n]
    jae .cfw_drop
    lea rcx, [rel cpw_warns]
    imul eax, ebx, CompWarn_size
    add rcx, rax
    push rcx
    lea rdi, [rcx + CompWarn.msg]
    call str_from_cstr_heap
    pop rcx
    test rax, rax
    jz .cfw_drop
    mov [rbp - CFW_ARGS], rax
    lea rax, [rel exc_SyntaxWarning_type]
    mov [rbp - CFW_ARGS + 8], rax
    mov rax, [rel cpw_file]
    mov [rbp - CFW_ARGS + 16], rax
    mov eax, [rcx + CompWarn.lineno]
    V_PACK_I64 rax, rdx
    mov [rbp - CFW_ARGS + 24], rax

    mov rdi, [rbp - CFW_FN]
    lea rsi, [rbp - CFW_ARGS]
    mov edx, 4
    call obj_call_n
    push rax
    mov rdi, [rbp - CFW_ARGS]
    call obj_decref
    pop rax
    test rax, rax
    jz .cfw_drop                ; a filter set to "error" raised it
    XDECREF_V rax, rcx
    inc ebx
    jmp .cfw_loop

.cfw_drop:
    mov dword [rel cpw_n], 0
    mov rdi, [rel cpw_file]
    test rdi, rdi
    jz .cfw_done
    mov qword [rel cpw_file], 0
    call obj_decref
.cfw_done:
    pop rbx
    leave
    ret
END_FUNC comp_flush_warnings

;; ============================================================================
;; cew_lookup_warn_explicit() -> rax = warnings.warn_explicit, or 0
;; Imported once and cached for the process, the way builtin_open_fn caches
;; _io's opener: importing it any earlier runs a module body.
;; ============================================================================
CLW_TMP   equ 8
CLW_MOD   equ 16
CLW_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
DEF_FUNC_LOCAL cew_lookup_warn_explicit, CLW_FRAME
    mov rax, [rel cew_warn_explicit]
    test rax, rax
    jnz .clw_done

    CSTRING rdi, "_warnings"
    call str_from_cstr_heap
    test rax, rax
    jz .clw_none
    mov [rbp - CLW_TMP], rax
    mov rdi, rax
    xor esi, esi
    xor edx, edx
    call import_module
    mov [rbp - CLW_MOD], rax
    mov rdi, [rbp - CLW_TMP]
    call obj_decref
    cmp qword [rbp - CLW_MOD], 0
    je .clw_none

    CSTRING rdi, "warn_explicit"
    call str_from_cstr_heap
    test rax, rax
    jz .clw_none
    mov [rbp - CLW_TMP], rax
    mov rdi, [rbp - CLW_MOD]
    mov rdi, [rdi + PyModuleObject.mod_dict]
    mov rsi, rax
    call dict_get
    mov [rbp - CLW_MOD], rax
    mov rdi, [rbp - CLW_TMP]
    call obj_decref
    mov rax, [rbp - CLW_MOD]
    test rax, rax
    jz .clw_none
    mov rdi, rax
    call obj_incref             ; the cache holds it for the process
    mov rax, [rbp - CLW_MOD]
    mov [rel cew_warn_explicit], rax
.clw_done:
    leave
    ret
.clw_none:
    ; Nothing could be imported.  Clear whatever the attempt left pending:
    ; a warning that cannot be emitted is not the program's error.
    mov rax, [gs:ThreadState.current_exception]
    test rax, rax
    jz .clw_zero
    mov qword [gs:ThreadState.current_exception], 0
    mov rdi, rax
    call obj_decref
.clw_zero:
    xor eax, eax
    leave
    ret
END_FUNC cew_lookup_warn_explicit

;; ============================================================================
;; comp_error(Comp *c, PyTypeObject *type, const char *msg, int lineno, int col)
;;   -> rax = 0, always, so callers can `jmp comp_error`-style tail into it and
;;      return the failure value in one go.
;;
;; The span defaults to the one character the error points at.  Where CPython's
;; is wider -- a whole token, or the subexpression a message is about -- the
;; caller says so with comp_error_span.
;; ============================================================================
DEF_FUNC_BARE comp_error
    push r9
    push r10
    mov r9d, ecx
    lea r10d, [r8d + 1]
    call comp_error_span
    pop r10
    pop r9
    ret
END_FUNC comp_error

;; ============================================================================
;; comp_error_span(Comp *c, PyTypeObject *type, const char *msg, int lineno,
;;                 int col, int end_lineno, int end_col) -> rax = 0, always
;;
;; The five fields a SyntaxError carries, all of them.  CPython's spans are not
;; all one character wide and not all forward: "expected 'except' or 'finally'
;; block" ends at column -1, meaning the end of the line, and every "was never
;; closed" ends at 0.  Both are passed through rather than normalised, because
;; a program that reads e.end_offset sees what CPython's would give it.
;; ============================================================================
DEF_FUNC_BARE comp_error_span
    cmp dword [rdi + Comp.err + CompErr.set], 0
    jne .already
    mov [rdi + Comp.err + CompErr.type], rsi
    mov [rdi + Comp.err + CompErr.msg], rdx
    mov [rdi + Comp.err + CompErr.lineno], ecx
    mov [rdi + Comp.err + CompErr.col], r8d
    mov [rdi + Comp.err + CompErr.end_lineno], r9d
    mov [rdi + Comp.err + CompErr.end_col], r10d
    mov dword [rdi + Comp.err + CompErr.set], 1
.already:
    xor eax, eax
    ret
END_FUNC comp_error_span

;; ============================================================================
;; comp_error_node(Comp *c, uint32_t node, const char *msg) -> rax = 0, always
;;
;; A SyntaxError at a NODE's own span, for the passes that have a node rather
;; than a token: the symbol table, and the pattern compiler.  Both used to
;; pass a literal ZERO for the line, and comp_attach_location derives the
;; source TEXT from the line -- so the message came out with line 0, offset 1,
;; no source line and no caret.
;;
;; The node's start is on the node; its end comes from the parallel span
;; table, and an end of -1 means it was never recorded, in which case the span
;; is the one character comp_error would have given.
;; ============================================================================
CEN_NODE  equ 8
CEN_MSG   equ 16
CEN_LINE  equ 24
CEN_COL   equ 32
CEN_FRAME equ 40                ; + 1 push = 48, 16-aligned
global comp_error_node
DEF_FUNC comp_error_node, CEN_FRAME
    push rbx
    mov rbx, rdi
    mov [rbp - CEN_NODE], rsi
    mov [rbp - CEN_MSG], rdx

    mov rdi, rbx
    mov esi, [rbp - CEN_NODE]
    call ast_at
    mov ecx, [rax + AstNode.lineno]
    mov [rbp - CEN_LINE], ecx
    mov ecx, [rax + AstNode.col]
    mov [rbp - CEN_COL], ecx

    mov rdi, rbx
    mov esi, [rbp - CEN_NODE]
    call ast_span_at
    mov ecx, [rbp - CEN_LINE]
    mov r8d, [rbp - CEN_COL]
    mov r9d, ecx
    lea r10d, [r8d + 1]
    test rax, rax
    jz .cen_go
    cmp dword [rax + AstSpan.end_lineno], -1
    je .cen_go
    mov r9d, [rax + AstSpan.end_lineno]
    mov r10d, [rax + AstSpan.end_col]
.cen_go:
    mov rdi, rbx
    lea rsi, [rel exc_SyntaxError_type]
    mov rdx, [rbp - CEN_MSG]
    call comp_error_span
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC comp_error_node

;; ============================================================================
;; comp_failed(Comp *c) -> rax = non-zero once an error has been recorded
;; ============================================================================
DEF_FUNC_BARE comp_failed
    mov eax, [rdi + Comp.err + CompErr.set]
    ret
END_FUNC comp_failed

;; ============================================================================
;; comp_source_span(rdi = Comp*, esi = a node index)
;;   -> rax = a pointer into Comp.src, rdx = its length; rax = 0 when the
;;      node carries no end position
;;
;; The source text the node was written as, from its start to its end.  What
;; PEP 563 stores in __annotations__.
;;
;; Both ends are (line, column) pairs: the start is in the node itself and the
;; end in the parallel AstSpan, whose end_lineno is -1 when it was never
;; recorded -- which is the one case this answers 0 for, so the caller can
;; fall back to evaluating the annotation as it always did.
;;
;; This is a SLICE, not an unparse.  CPython emits the text its own unparser
;; produces, so `x: (int)` is 'int' there and '(int)' here, and a multi-line
;; annotation keeps its newlines; DIVERGENCES.md records that.  Everything
;; the difference costs is cosmetic -- the string still evaluates to the same
;; object, which is what typing.get_type_hints does with it.
;; ============================================================================
CSS_NODE  equ 8
CSS_ENDL  equ 16
CSS_ENDC  equ 24
CSS_START equ 32
CSS_FRAME equ 40            ; + 1 push = 48, 16-aligned
global comp_source_span
DEF_FUNC comp_source_span, CSS_FRAME
    push rbx
    mov rbx, rdi
    mov [rbp - CSS_NODE], rsi

    mov rdi, rbx
    mov esi, [rbp - CSS_NODE]
    call ast_span_at
    test rax, rax
    jz .css_none
    mov ecx, [rax + AstSpan.end_lineno]
    cmp ecx, -1
    je .css_none
    movsxd rcx, ecx
    mov [rbp - CSS_ENDL], rcx
    mov ecx, [rax + AstSpan.end_col]
    movsxd rcx, ecx
    mov [rbp - CSS_ENDC], rcx

    mov rdi, rbx
    mov rsi, [rbp - CSS_NODE]
    call ast_at
    test rax, rax
    jz .css_none
    mov edx, [rax + AstNode.lineno]
    mov ecx, [rax + AstNode.col]
    mov rdi, rbx
    movsxd rsi, edx
    movsxd rdx, ecx
    call css_offset
    cmp rax, -1
    je .css_none
    mov [rbp - CSS_START], rax

    mov rdi, rbx
    mov rsi, [rbp - CSS_ENDL]
    mov rdx, [rbp - CSS_ENDC]
    call css_offset
    cmp rax, -1
    je .css_none
    sub rax, [rbp - CSS_START]
    jle .css_none
    mov rdx, rax
    mov rax, [rbx + Comp.src]
    add rax, [rbp - CSS_START]
    pop rbx
    leave
    ret
.css_none:
    xor eax, eax
    xor edx, edx
    pop rbx
    leave
    ret
END_FUNC comp_source_span

;; ============================================================================
;; css_offset(rdi = Comp*, rsi = a 1-based line, rdx = a 0-based column)
;;   -> rax = the byte offset into Comp.src, or -1
;;
;; The column is a BYTE offset within the line, which is what the lexer
;; records; a source with a multi-byte character before the annotation is
;; therefore sliced correctly without any code-point arithmetic.
;; ============================================================================
CSO_COL   equ 8
CSO_FRAME equ 16            ; + 1 push = 24... 16 + 8 = 24, so pad
DEF_FUNC_LOCAL css_offset, 8
    push rbx
    mov rbx, rdi
    cmp rsi, 1
    jl .cso_none
    mov r8, [rbx + Comp.src]
    test r8, r8
    jz .cso_none
    xor ecx, ecx                        ; byte position
    mov r9d, 1                          ; current line
.cso_scan:
    cmp r9, rsi
    jae .cso_at_line
    cmp rcx, [rbx + Comp.srclen]
    jae .cso_none
    cmp byte [r8 + rcx], 10
    jne .cso_next
    inc r9
.cso_next:
    inc rcx
    jmp .cso_scan
.cso_at_line:
    add rcx, rdx
    cmp rcx, [rbx + Comp.srclen]
    ja .cso_none
    mov rax, rcx
    pop rbx
    leave
    ret
.cso_none:
    mov rax, -1
    pop rbx
    leave
    ret
END_FUNC css_offset
