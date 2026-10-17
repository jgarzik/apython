;; ============================================================================
;; traceback.asm -- the code object's side tables, and traceback rendering
;;
;; Both compressed tables CPython hangs off a code object are decoded here:
;; co_linetable, for the line a traceback names, and co_exceptiontable, for
;; the handler the unwinder jumps to.  They are different encodings of the
;; same idea -- a varint stream indexed by instruction offset -- and the two
;; varint readers below are siblings.
;;
;; Python 3.12 stores locations in co_linetable using the PEP 626 format: each
;; entry begins with a byte 0x80 | (code << 3) | (length - 1), where `length`
;; is how many code units the entry covers and `code` selects what follows.
;; Only the line delta matters here; the column fields are decoded far enough
;; to be skipped.
;;
;;   code 0-9   short form, one trailing byte, line delta 0
;;   code 10-12 one-line form, two trailing bytes, line delta = code - 10
;;   code 13    no columns, one signed varint line delta
;;   code 14    long form, signed varint line delta then three varints
;;   code 15    no location at all
;;
;; The renderer walks the chain a raise builds -- newest entry at the head, so
;; tb_next order is outermost first, "most recent call last" -- and prints what
;; CPython's default excepthook prints, including the __cause__ / __context__
;; preamble.
;; ============================================================================

%include "object.inc"
%include "macros.inc"
%include "value.inc"

extern sys_write
extern sys_open
extern sys_read
extern sys_close
extern obj_str
extern exc_is_syntax
extern str_type
extern ap_strcmp
extern tuple_type
extern obj_decref
extern str_type
extern none_singleton
extern obj_dealloc
extern traceback_type
extern ap_malloc

TB_CHUNK equ 4096
TB_LINE  equ 1024
TB_PATH  equ 4096

section .text

;; ============================================================================
;; tb_read_varint -- reads a PEP 626 varint from [r8], advancing r8.
;; Result in ecx.  rax, rdx, rsi, r9, r10 are preserved; r11 is clobbered.
;; ============================================================================
DEF_FUNC_BARE tb_read_varint
    push rax
    push rdx
    xor eax, eax                    ; accumulated value
    xor edx, edx                    ; shift
.rv_loop:
    movzx r11d, byte [r8]
    inc r8
    and r11d, 63
    push rcx
    mov ecx, edx
    shl r11, cl
    pop rcx
    or rax, r11
    add edx, 6
    movzx r11d, byte [r8 - 1]
    test r11d, 64
    jnz .rv_loop
    mov ecx, eax
    pop rdx
    pop rax
    ret
END_FUNC tb_read_varint

;; ============================================================================
;; tb_read_svarint -- zig-zag signed varint; result in ecx.
;; ============================================================================
DEF_FUNC_BARE tb_read_svarint
    call tb_read_varint
    mov r11d, ecx
    shr ecx, 1
    test r11d, 1
    jz .sv_done
    neg ecx
.sv_done:
    ret
END_FUNC tb_read_svarint

;; ============================================================================
;; code_addr2line(rdi = PyCodeObject*, rsi = instruction offset in code units)
;;   -> eax = line number, or 0 when the table does not cover the offset
;; ============================================================================
DEF_FUNC_BARE code_addr2line
    mov r8, [rdi + PyCodeObject.co_linetable]
    test r8, r8
    jz .a2l_none
    mov eax, [rdi + PyCodeObject.co_firstlineno]    ; running line
    mov r9, [r8 + PyBytesObject.ob_size]
    lea r8, [r8 + PyBytesObject.data]               ; cursor
    add r9, r8                                      ; end
    xor r10d, r10d                                  ; code-unit offset of entry

.a2l_entry:
    cmp r8, r9
    jae .a2l_none
    movzx ecx, byte [r8]
    inc r8
    test cl, 0x80
    jz .a2l_none                                    ; desynchronised
    mov edx, ecx
    and edx, 7
    inc edx                                         ; edx = length in units
    shr ecx, 3
    and ecx, 0x0f                                   ; ecx = code

    cmp ecx, 15
    je .a2l_check                                   ; no location, delta 0
    cmp ecx, 14
    je .a2l_long
    cmp ecx, 13
    je .a2l_nocol
    cmp ecx, 10
    jb .a2l_short
    sub ecx, 10                                     ; one-line form
    add eax, ecx
    add r8, 2
    jmp .a2l_check

.a2l_short:
    inc r8
    jmp .a2l_check

.a2l_nocol:
    call tb_read_svarint
    add eax, ecx
    jmp .a2l_check

.a2l_long:
    call tb_read_svarint
    push rcx                                        ; line delta
    call tb_read_varint                             ; end line delta
    call tb_read_varint                             ; start column + 1
    call tb_read_varint                             ; end column + 1
    pop rcx
    add eax, ecx

.a2l_check:
    cmp rsi, r10
    jb .a2l_advance
    lea r11, [r10 + rdx]
    cmp rsi, r11
    jae .a2l_advance
    ret                                             ; eax = line

.a2l_advance:
    add r10, rdx
    jmp .a2l_entry

.a2l_none:
    xor eax, eax
    ret
END_FUNC code_addr2line

;; ============================================================================
;; code_addr2location(rdi = PyCodeObject*, rsi = offset in code units,
;;                    rdx = out: four qwords, start_line, end_line,
;;                                start_col, end_col)
;;   -> eax = 1 when the table covers the offset, 0 otherwise
;;
;; code_addr2location_at takes a fourth argument: rcx = a three-word RESUME
;; cursor owned by the caller, or 0 for none.  A walk that asks about
;; ascending offsets -- which is what co_lines() and co_positions() do, once
;; per code unit -- otherwise rescans the table from byte zero every time, so
;; listing a code object's lines costs the SQUARE of its length.  For the
;; hundred-thousand-line function CPython's test_jump_extended_args_for_iter
;; builds, that is not slow but indefinite: unittest formats the failure's
;; traceback through co_positions(), and the whole module timed out, so none
;; of its 438 tests ran.  CPython walks the table once.
;;
;; The cursor holds the state at the START of the entry last matched -- byte
;; cursor, that entry's code-unit offset, and the running line before its
;; delta was applied -- so resuming re-decodes that entry and moves forward
;; from it; the next offset asked about is usually still inside it.  Asking
;; about an offset BELOW the cursor is still correct: the scan starts over.
;; Zero the three words before the first call; that means "no state yet".
;;
;; It lives in the CALLER's frame deliberately, not on the code object and not
;; in a global.  A cursor that outlives its walk would have to be invalidated
;; when the code object dies, and an address is reused where a version is not:
;; a stale cursor whose code pointer matches a new object at the same address
;; decodes another table's bytes.  One that cannot outlive the loop cannot go
;; stale.
;;
;; The same walk as code_addr2line, keeping the columns this time.  The
;; columns are BYTE offsets into the source line, zero-based; -1 means the
;; entry does not carry them, which is what CPython reports for a NO_COLUMNS
;; or NONE entry and what makes it skip the caret line.
;;
;; The five entry shapes, from CPython's Objects/locations.md:
;;   code 0-9   one byte follows: col = code*8 + (b >> 4),
;;              end_col = col + (b & 15); same line
;;   code 10-12 two raw bytes: col, end_col; line delta = code - 10
;;   code 13    signed varint line delta; no columns
;;   code 14    signed varint line delta, then end-line delta, col+1, end_col+1
;;   code 15    no location at all
;; ============================================================================
A2C_OUT   equ 8
A2C_LINE  equ 16
A2C_STATE equ 24            ; the caller's resume cursor, or 0
A2C_SCUR  equ 32            ; byte cursor at the current entry's first byte
A2C_SOFF  equ 40            ; that entry's code-unit offset
A2C_SLINE equ 48            ; the running line before that entry's delta
A2C_FRAME equ 64            ; + 4 pushes = 96, 16-aligned

DEF_FUNC code_addr2location
    xor ecx, ecx                ; no resume cursor
    leave
    jmp code_addr2location_at
END_FUNC code_addr2location

;; ============================================================================
;; code_addr2location_at(rdi = PyCodeObject*, rsi = offset in code units,
;;                       rdx = out: four qwords, rcx = a three-word resume
;;                       cursor owned by the caller, or 0)
;;   -> eax = 1 when the table covers the offset, 0 otherwise
;;
;; The body of both.  See code_addr2location above for what the cursor is for
;; and why it belongs to the caller.
;; ============================================================================
global code_addr2location_at
DEF_FUNC code_addr2location_at, A2C_FRAME
    mov [rbp - A2C_STATE], rcx
    push rbx
    push r12
    push r13
    push r14
    mov [rbp - A2C_OUT], rdx
    mov qword [rdx], -1
    mov qword [rdx + 8], -1
    mov qword [rdx + 16], -1
    mov qword [rdx + 24], -1

    test rdi, rdi
    jz .a2c_none
    mov r14, [rdi + PyCodeObject.co_linetable]
    test r14, r14
    jz .a2c_none
    mov rax, [r14 + PyObject.ob_type]
    extern bytes_type
    lea rcx, [rel bytes_type]
    cmp rax, rcx
    jne .a2c_none

    mov eax, [rdi + PyCodeObject.co_firstlineno]
    mov [rbp - A2C_LINE], rax
    mov r9, [r14 + PyBytesObject.ob_size]
    lea r8, [r14 + PyBytesObject.data]          ; cursor
    add r9, r8                                  ; end
    xor r10d, r10d                              ; code-unit offset of entry

    ; Resume, when the caller kept a cursor and is asking at or after the entry
    ; it left off at.  A cursor from another table fails the range test and a
    ; backwards question fails the offset test; both start over, which is
    ; correct, only slower.
    mov rcx, [rbp - A2C_STATE]
    test rcx, rcx
    jz .a2c_entry
    mov rax, [rcx]
    cmp rax, r8
    jb .a2c_entry
    cmp rax, r9
    jae .a2c_entry
    cmp rsi, [rcx + 8]
    jb .a2c_entry
    mov r8, rax
    mov r10, [rcx + 8]
    mov rax, [rcx + 16]
    mov [rbp - A2C_LINE], rax

.a2c_entry:
    ; Where this entry begins, so a hit hands back a cursor that re-decodes it
    ; rather than one already past it.
    mov [rbp - A2C_SCUR], r8
    mov [rbp - A2C_SOFF], r10
    mov rax, [rbp - A2C_LINE]
    mov [rbp - A2C_SLINE], rax
    cmp r8, r9
    jae .a2c_none
    movzx ecx, byte [r8]
    inc r8
    test cl, 0x80
    jz .a2c_none                                ; desynchronised
    mov edx, ecx
    and edx, 7
    inc edx                                     ; edx = length in code units
    shr ecx, 3
    and ecx, 0x0f                               ; ecx = code
    mov ebx, ecx                                ; ebx = code, kept across reads

    xor r12d, r12d                              ; start col, or -1
    xor r13d, r13d                              ; end col, or -1
    mov r12d, -1
    mov r13d, -1

    cmp ebx, 15
    je .a2c_check                               ; no location: line delta 0
    cmp ebx, 14
    je .a2c_long
    cmp ebx, 13
    je .a2c_nocol
    cmp ebx, 10
    jb .a2c_short

    ; one-line form: two raw column bytes, line delta in the code
    lea eax, [rbx - 10]
    add [rbp - A2C_LINE], eax
    movzx r12d, byte [r8]
    movzx r13d, byte [r8 + 1]
    add r8, 2
    jmp .a2c_check

.a2c_short:
    movzx eax, byte [r8]
    inc r8
    mov r12d, ebx
    shl r12d, 3                                 ; code * 8
    mov ecx, eax
    shr ecx, 4
    add r12d, ecx                               ; start column
    mov r13d, eax
    and r13d, 15
    add r13d, r12d                              ; end column
    jmp .a2c_check

.a2c_nocol:
    call tb_read_svarint
    add [rbp - A2C_LINE], ecx
    jmp .a2c_check

.a2c_long:
    call tb_read_svarint
    add [rbp - A2C_LINE], ecx
    call tb_read_varint
    mov r12d, ecx                               ; end line delta, for now
    call tb_read_varint
    mov r13d, ecx                               ; start column + 1
    call tb_read_varint                         ; end column + 1
    ; Fold the three into place below; r12 is the end-line delta here, so it
    ; is dealt with at .a2c_hit rather than in the common tail.
    mov eax, r12d
    mov r12d, r13d
    dec r12d                                    ; -1 when the field was 0
    mov r13d, ecx
    dec r13d
    push rax                                    ; the end-line delta
    jmp .a2c_check_long

.a2c_check_long:
    cmp rsi, r10
    jb .a2c_advance_long
    lea r11, [r10 + rdx]
    cmp rsi, r11
    jae .a2c_advance_long
    pop rax
    mov rdx, [rbp - A2C_OUT]
    mov rcx, [rbp - A2C_LINE]
    mov [rdx], rcx
    add rax, rcx
    mov [rdx + 8], rax                          ; end line
    movsxd rax, r12d
    mov [rdx + 16], rax
    movsxd rax, r13d
    mov [rdx + 24], rax
    mov eax, 1
    jmp .a2c_hit
.a2c_advance_long:
    pop rax
    add r10, rdx
    jmp .a2c_entry

.a2c_check:
    cmp rsi, r10
    jb .a2c_advance
    lea r11, [r10 + rdx]
    cmp rsi, r11
    jae .a2c_advance
    mov rdx, [rbp - A2C_OUT]
    cmp ebx, 15
    je .a2c_out_none                            ; no location for this range
    mov rcx, [rbp - A2C_LINE]
    mov [rdx], rcx
    mov [rdx + 8], rcx                          ; every other form is one line
    movsxd rax, r12d
    mov [rdx + 16], rax
    movsxd rax, r13d
    mov [rdx + 24], rax
    mov eax, 1
    jmp .a2c_hit

.a2c_advance:
    add r10, rdx
    jmp .a2c_entry

.a2c_out_none:
    mov eax, 1
    jmp .a2c_hit
.a2c_none:
    xor eax, eax
    jmp .a2c_out

.a2c_hit:
    ; Hand the cursor back, so the caller's next question resumes here.
    mov rcx, [rbp - A2C_STATE]
    test rcx, rcx
    jz .a2c_out
    mov rdx, [rbp - A2C_SCUR]
    mov [rcx], rdx
    mov rdx, [rbp - A2C_SOFF]
    mov [rcx + 8], rdx
    mov rdx, [rbp - A2C_SLINE]
    mov [rcx + 16], rdx

.a2c_out:
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC code_addr2location_at

;; ============================================================================
;; traceback_here(rdi = exception, rsi = code object, rdx = lasti in code units)
;; Prepends a frame to the exception's traceback, as PyTraceBack_Here does.
;; ============================================================================
TH_EXC   equ 8
TH_CODE  equ 16
TH_LASTI equ 24
TH_TB    equ 32
TH_FRAME equ 32             ; + 0 pushes = 32
DEF_FUNC traceback_here, TH_FRAME
    mov [rbp - TH_EXC], rdi
    mov [rbp - TH_CODE], rsi
    mov [rbp - TH_LASTI], rdx

    mov edi, PyTracebackObject_size
    call ap_malloc
    mov qword [rax + PyObject.ob_refcnt], 1
    lea rcx, [rel traceback_type]
    mov [rax + PyObject.ob_type], rcx
    mov qword [rax + PyTracebackObject.tb_lineno], 0

    mov rcx, [rbp - TH_EXC]
    mov rdx, [rcx + PyExceptionObject.exc_tb]
    mov [rax + PyTracebackObject.tb_next], rdx      ; adopts the old chain
    mov rdx, [rbp - TH_CODE]
    mov [rax + PyTracebackObject.tb_code], rdx
    mov rdx, [rbp - TH_LASTI]
    mov [rax + PyTracebackObject.tb_lasti], rdx
    mov [rcx + PyExceptionObject.exc_tb], rax
    mov [rbp - TH_TB], rax

    mov rdi, [rbp - TH_CODE]
    test rdi, rdi
    jz .th_done
    ; The code object must outlive the frame it came from.
    inc qword [rdi + PyObject.ob_refcnt]
    mov rsi, [rbp - TH_LASTI]
    call code_addr2line
    movsx rax, eax
    mov rcx, [rbp - TH_TB]
    mov [rcx + PyTracebackObject.tb_lineno], rax
.th_done:
    leave
    ret
END_FUNC traceback_here

;; ============================================================================
;; tb_write(rdi = buf, rsi = len) -- stderr
;; ============================================================================
DEF_FUNC_BARE tb_write
    mov rdx, rsi
    mov rsi, rdi
    mov edi, 2
    jmp sys_write
END_FUNC tb_write

;; ============================================================================
;; tb_write_cstr(rdi = NUL-terminated string)
;; ============================================================================
DEF_FUNC tb_write_cstr, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    xor ecx, ecx
.len:
    cmp byte [rbx + rcx], 0
    je .have
    inc rcx
    jmp .len
.have:
    mov rdi, rbx
    mov rsi, rcx
    call tb_write
    pop rbx
    leave
    ret
END_FUNC tb_write_cstr

;; ============================================================================
;; tb_write_str(rdi = PyStrObject* or NULL) -- writes nothing for a non-str
;; ============================================================================
DEF_FUNC tb_write_str
    test rdi, rdi
    jz .ws_out
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    jne .ws_out
    mov rsi, [rdi + PyStrObject.ob_size]
    add rdi, PyStrObject.data
    call tb_write
.ws_out:
    leave
    ret
END_FUNC tb_write_str

;; ============================================================================
;; tb_write_dec(rdi = signed value)
;; ============================================================================
TD_BUF   equ 32
TD_FRAME equ 48             ; + 0 pushes = 48
DEF_FUNC tb_write_dec, TD_FRAME
    mov rax, rdi
    lea rcx, [rbp - TD_BUF]
    add rcx, 24                     ; one past the digit area
    mov r8, rcx
    xor r9d, r9d
    test rax, rax
    jns .td_pos
    mov r9d, 1
    neg rax
.td_pos:
    mov r10d, 10
.td_loop:
    xor edx, edx
    div r10
    add dl, '0'
    dec rcx
    mov [rcx], dl
    test rax, rax
    jnz .td_loop
    test r9d, r9d
    jz .td_out
    dec rcx
    mov byte [rcx], '-'
.td_out:
    mov rdi, rcx
    mov rsi, r8
    sub rsi, rcx
    call tb_write
    leave
    ret
END_FUNC tb_write_dec

;; ============================================================================
;; tb_write_carets(rdi = the raw source line, rsi = its length in bytes,
;;                 rdx = how many leading whitespace bytes were stripped,
;;                 rcx = the four-qword location)
;;
;; CPython's tb_displayline, in the same order:
;;
;;   * the columns are byte offsets into the line and the carets are drawn in
;;     characters, so both ends are converted first;
;;   * on one line, the segment between them decides whether there are inner
;;     anchors -- `~~^~~` rather than `^^^^^`;
;;   * across lines, the highlight runs to the last non-whitespace character;
;;   * and when the primary run covers the whole stripped line and there are
;;     no inner anchors, the row is left out entirely, because underlining a
;;     line with itself says nothing.
;;
;; The row starts at the stripped indentation minus four, which is what puts
;; the first caret under the right column of a line printed with a four-space
;; indent.  It is arithmetic on signed offsets: with no indentation at all
;; the counter starts at -4.
;; ============================================================================
TC_LINE  equ 8
TC_LEN   equ 16
TC_I     equ 24
TC_LOC   equ 32
TC_ANCH  equ 48             ; two qwords
TC_START equ 56
TC_END   equ 64
TC_LEFT  equ 72
TC_RIGHT equ 80
TC_PRIM  equ 88
TC_SEC   equ 96
TC_SEGB  equ 104            ; the segment's start, as a clamped byte offset
TC_BUF   equ 112 + TB_LINE
TC_FRAME equ TC_BUF + 16    ; + 2 pushes = TC_BUF + 32

DEF_FUNC_LOCAL tb_write_carets, TC_FRAME
    push rbx
    push r12
    mov [rbp - TC_LINE], rdi
    mov [rbp - TC_LEN], rsi
    mov [rbp - TC_I], rdx
    mov [rbp - TC_LOC], rcx
    mov byte [rbp - TC_PRIM], '^'
    mov byte [rbp - TC_SEC], '^'
    mov qword [rbp - TC_LEFT], -1
    mov qword [rbp - TC_RIGHT], -1

    ; No location, or no columns: CPython prints the line and no carets.
    cmp qword [rcx], 0
    jl .tc_out
    mov rax, [rcx + 16]
    test rax, rax
    jl .tc_out
    mov rdx, [rcx + 24]
    test rdx, rdx
    jl .tc_out
    ; Clamp rather than give up: the end column of an expression that runs
    ; past this line is a column on a LATER line, and the multi-line branch
    ; below replaces it anyway.
    cmp rax, rsi
    jbe .tc_start_ok
    mov rax, rsi
.tc_start_ok:
    cmp rdx, rsi
    jbe .tc_end_ok
    mov rdx, rsi
.tc_end_ok:

    ; Byte offsets to character offsets.
    mov rdi, [rbp - TC_LINE]
    mov rsi, rax
    push rdx
    call tb_byte_to_char
    pop rdx
    mov [rbp - TC_START], rax
    mov rdi, [rbp - TC_LINE]
    mov rsi, rdx
    call tb_byte_to_char
    mov [rbp - TC_END], rax

    mov rcx, [rbp - TC_LOC]
    mov rax, [rcx]
    cmp rax, [rcx + 8]
    jne .tc_multiline

    ; One line: ask the segment whether it has inner anchors.  The columns are
    ; clamped to the line, so a truncated line cannot walk off the buffer.
    mov rdi, [rbp - TC_LINE]
    mov rax, [rcx + 16]
    cmp rax, [rbp - TC_LEN]
    jbe .tc_seg_start_ok
    mov rax, [rbp - TC_LEN]
.tc_seg_start_ok:
    mov [rbp - TC_SEGB], rax
    add rdi, rax
    mov rsi, [rcx + 24]
    cmp rsi, [rbp - TC_LEN]
    jbe .tc_seg_end_ok
    mov rsi, [rbp - TC_LEN]
.tc_seg_end_ok:
    sub rsi, rax
    jle .tc_measure
    lea rdx, [rbp - TC_ANCH]
    call tb_anchors
    test eax, eax
    jz .tc_measure
    ; The anchors are byte offsets within the segment; CPython converts them
    ; the same way and adds the segment's own start.
    mov rdi, [rbp - TC_LINE]
    add rdi, [rbp - TC_SEGB]
    mov rsi, [rbp - TC_ANCH]
    call tb_byte_to_char
    add rax, [rbp - TC_START]
    mov [rbp - TC_LEFT], rax
    mov rdi, [rbp - TC_LINE]
    add rdi, [rbp - TC_SEGB]
    mov rsi, [rbp - TC_ANCH + 8]
    call tb_byte_to_char
    add rax, [rbp - TC_START]
    mov [rbp - TC_RIGHT], rax
    mov byte [rbp - TC_PRIM], '~'
    mov byte [rbp - TC_SEC], '^'
    jmp .tc_measure

.tc_multiline:
    ; The expression runs past this line: highlight to its last
    ; non-whitespace character.
    mov rdx, [rbp - TC_LEN]
.tc_ml_scan:
    test rdx, rdx
    jz .tc_ml_done
    mov rax, [rbp - TC_LINE]
    movzx ecx, byte [rax + rdx - 1]
    cmp cl, ' '
    je .tc_ml_next
    cmp cl, 9
    je .tc_ml_next
    cmp cl, 12
    je .tc_ml_next
    cmp cl, 13
    je .tc_ml_next
    cmp cl, 10
    jne .tc_ml_done
.tc_ml_next:
    dec rdx
    jmp .tc_ml_scan
.tc_ml_done:
    mov rdi, [rbp - TC_LINE]
    mov rsi, rdx
    call tb_byte_to_char
    mov [rbp - TC_END], rax

.tc_measure:
    ; Elide the row when the primary run is the whole stripped line.
    mov rax, [rbp - TC_LEFT]
    test rax, rax
    jge .tc_emit
    cmp qword [rbp - TC_RIGHT], 0
    jge .tc_emit
    mov rdi, [rbp - TC_LINE]
    mov rsi, [rbp - TC_LEN]
    call tb_byte_to_char        ; the line's length in characters
    sub rax, [rbp - TC_I]       ; the stripped length; the indent is ASCII
    mov rcx, [rbp - TC_END]
    sub rcx, [rbp - TC_START]
    cmp rcx, rax
    je .tc_out

.tc_emit:
    ; offset = i - 4, then one character per ++offset up to end.
    mov rbx, [rbp - TC_I]
    sub rbx, 4                  ; the counter, signed
    xor r12, r12                ; bytes in the buffer
.tc_loop:
    inc rbx
    cmp rbx, [rbp - TC_END]
    jg .tc_flush
    cmp r12, TB_LINE - 1
    jae .tc_flush
    mov al, ' '
    cmp rbx, [rbp - TC_START]
    jle .tc_put
    mov al, [rbp - TC_PRIM]
    cmp qword [rbp - TC_LEFT], 0
    jl .tc_put
    cmp rbx, [rbp - TC_LEFT]
    jle .tc_put
    cmp rbx, [rbp - TC_RIGHT]
    jg .tc_put
    mov al, [rbp - TC_SEC]
.tc_put:
    lea rcx, [rbp - TC_BUF]
    mov [rcx + r12], al
    inc r12
    jmp .tc_loop

.tc_flush:
    test r12, r12
    jz .tc_out
    lea rdi, [rbp - TC_BUF]
    mov rsi, r12
    call tb_write
    CSTRING rdi, `\n`
    call tb_write_cstr
.tc_out:
    pop r12
    pop rbx
    leave
    ret
END_FUNC tb_write_carets

;; tb_byte_to_char(rdi = buffer, rsi = a byte offset) -> rax = the character
;; offset, counting UTF-8 lead bytes.  An ASCII line, which is nearly every
;; line, answers rsi.
DEF_FUNC_BARE tb_byte_to_char
    xor eax, eax
    xor ecx, ecx
.b2c_loop:
    cmp rcx, rsi
    jae .b2c_done
    mov dl, [rdi + rcx]
    and dl, 0xC0
    cmp dl, 0x80
    je .b2c_next
    inc rax
.b2c_next:
    inc rcx
    jmp .b2c_loop
.b2c_done:
    ret
END_FUNC tb_byte_to_char

;; ============================================================================
;; tb_anchors(rdi = segment, rsi = length, rdx = out: left, right byte offsets)
;;   -> eax = 1 when the segment is a top-level binary operation or subscript
;;
;; CPython parses the segment with the real parser and looks at the one node
;; it produces: only a BinOp or a Subscript gets the `~~^~~` treatment, and
;; anything else -- a call, a comparison, a boolean operator, a tuple -- gets
;; a plain row of carets.  Running the compiler from inside the unwinder is
;; not an option, so this reads the same answer off a token scan:
;;
;;   * the top-level BinOp's operator is the one of lowest precedence at
;;     bracket depth zero, the last of its kind because they associate left --
;;     except `**`, which associates right, so there the first;
;;   * anything that would make the top node something other than a BinOp --
;;     a comma, a comparison, `and`, `or`, `not`, `if`, `lambda`, a colon --
;;     rules the segment out entirely;
;;   * failing that, a segment ending in `]` whose matching `[` follows an
;;     operand is a subscript.
;;
;; The offsets are bytes within the segment, as CPython's are before it
;; converts them.
;; ============================================================================
AN_OUT   equ 8
AN_PREC  equ 16             ; best (lowest) precedence seen, 99 for none
AN_IDX   equ 24             ; byte offset of that operator
AN_LEN   equ 32             ; its length, 1 or 2
AN_DISQ  equ 40             ; the segment cannot be a BinOp or Subscript
AN_SOPEN equ 48             ; `[` of the last depth-0 subscript, or -1
AN_SCLOSE equ 56            ; its `]`, or -1
AN_FRAME equ 72            ; + 5 pushes = 112, 16-aligned

; Precedence, lowest binding first.  Only the binary operators appear.
AN_P_OR   equ 1
AN_P_XOR  equ 2
AN_P_AND  equ 3
AN_P_SHIFT equ 4
AN_P_ADD  equ 5
AN_P_MUL  equ 6
AN_P_POW  equ 7

DEF_FUNC tb_anchors, AN_FRAME
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    mov r12, rsi
    mov [rbp - AN_OUT], rdx
    mov qword [rbp - AN_PREC], 99
    mov qword [rbp - AN_IDX], -1
    mov qword [rbp - AN_LEN], 0
    mov qword [rbp - AN_DISQ], 0
    mov qword [rbp - AN_SOPEN], -1
    mov qword [rbp - AN_SCLOSE], -1
    xor r13, r13                    ; i
    xor r14, r14                    ; bracket depth
    xor r15, r15                    ; 1 = the previous token can end an operand

.an_loop:
    cmp r13, r12
    jae .an_end
    movzx eax, byte [rbx + r13]

    cmp al, ' '
    je .an_skip1
    cmp al, 9
    je .an_skip1
    cmp al, 12
    je .an_skip1
    cmp al, 13
    je .an_skip1
    cmp al, 10
    je .an_skip1

    cmp al, '#'
    je .an_end                      ; a comment ends the expression

    cmp al, 39                      ; '
    je .an_string
    cmp al, '"'
    je .an_string

    cmp al, '('
    je .an_open
    cmp al, '['
    je .an_open_sq
    cmp al, '{'
    je .an_open
    cmp al, ')'
    je .an_close
    cmp al, ']'
    je .an_close_sq
    cmp al, '}'
    je .an_close

    ; a name, or a string prefix.  A byte at or above 0x80 is part of a
    ; non-ASCII identifier -- `ä / b` is a division like any other -- and
    ; falling through to .an_operator for it made the whole expression the
    ; caret span rather than anchoring on the operator.
    cmp al, 0x80
    jae .an_name
    cmp al, '_'
    je .an_name
    or al, 0x20
    cmp al, 'a'
    jb .an_maybe_digit
    cmp al, 'z'
    jbe .an_name
.an_maybe_digit:
    movzx eax, byte [rbx + r13]
    cmp al, '0'
    jb .an_operator
    cmp al, '9'
    jbe .an_number
    jmp .an_operator

.an_skip1:
    inc r13
    jmp .an_loop

.an_open:
    inc r14
    inc r13
    xor r15, r15
    jmp .an_loop

.an_open_sq:
    ; A `[` after an operand opens a subscript; after anything else it is a
    ; list display, which is not what the anchor rule is about.
    test r14, r14
    jnz .an_open_sq_deep
    test r15, r15
    jz .an_open_sq_deep
    mov [rbp - AN_SOPEN], r13
.an_open_sq_deep:
    inc r14
    inc r13
    xor r15, r15
    jmp .an_loop

.an_close:
    dec r14
    inc r13
    mov r15d, 1
    jmp .an_loop

.an_close_sq:
    dec r14
    test r14, r14
    jnz .an_close_sq_deep
    cmp qword [rbp - AN_SOPEN], 0
    jl .an_close_sq_deep
    mov [rbp - AN_SCLOSE], r13
.an_close_sq_deep:
    inc r13
    mov r15d, 1
    jmp .an_loop

.an_string:
    ; Skip a string literal, single or triple quoted, honouring backslashes.
    mov cl, al                      ; the quote character
    mov rdx, r13
    inc rdx
    ; triple?
    lea rax, [r13 + 2]
    cmp rax, r12
    jae .an_str_single
    cmp cl, [rbx + r13 + 1]
    jne .an_str_single
    cmp cl, [rbx + r13 + 2]
    jne .an_str_single
    add rdx, 2
.an_str_triple:
    cmp rdx, r12
    jae .an_str_done
    mov al, [rbx + rdx]
    cmp al, 92                      ; backslash
    je .an_str_triple_esc
    cmp al, cl
    jne .an_str_triple_next
    lea rax, [rdx + 2]
    cmp rax, r12
    jae .an_str_triple_next
    cmp cl, [rbx + rdx + 1]
    jne .an_str_triple_next
    cmp cl, [rbx + rdx + 2]
    jne .an_str_triple_next
    add rdx, 3
    jmp .an_str_done
.an_str_triple_esc:
    inc rdx
.an_str_triple_next:
    inc rdx
    jmp .an_str_triple

.an_str_single:
    cmp rdx, r12
    jae .an_str_done
    mov al, [rbx + rdx]
    cmp al, 92
    je .an_str_single_esc
    cmp al, cl
    je .an_str_single_close
    cmp al, 10
    je .an_str_done
    inc rdx
    jmp .an_str_single
.an_str_single_esc:
    add rdx, 2
    jmp .an_str_single
.an_str_single_close:
    inc rdx
.an_str_done:
    mov r13, rdx
    mov r15d, 1
    jmp .an_loop

.an_name:
    ; Read the identifier, then decide whether it is a keyword that rules the
    ; segment out, or a string prefix, or an ordinary name.
    mov rdx, r13
.an_name_scan:
    cmp rdx, r12
    jae .an_name_done
    movzx eax, byte [rbx + rdx]
    cmp al, 0x80
    jae .an_name_next           ; a continuation or lead byte of a non-ASCII
                                ; identifier; stopping here left the cursor
                                ; where it was and the scan spun forever
    cmp al, '_'
    je .an_name_next
    cmp al, '0'
    jb .an_name_done
    cmp al, '9'
    jbe .an_name_next
    or al, 0x20
    cmp al, 'a'
    jb .an_name_done
    cmp al, 'z'
    ja .an_name_done
.an_name_next:
    inc rdx
    jmp .an_name_scan
.an_name_done:
    ; A prefix immediately followed by a quote is a string, not a name.
    cmp rdx, r12
    jae .an_name_plain
    movzx eax, byte [rbx + rdx]
    cmp al, 39
    je .an_name_string
    cmp al, '"'
    jne .an_name_plain
.an_name_string:
    mov r13, rdx
    movzx eax, byte [rbx + r13]
    jmp .an_string
.an_name_plain:
    test r14, r14
    jnz .an_name_ordinary          ; inside brackets nothing disqualifies
    mov rdi, rbx
    add rdi, r13
    mov rsi, rdx
    sub rsi, r13
    push rdx
    call tb_anchor_keyword
    pop rdx
    test eax, eax
    jz .an_name_ordinary
    mov qword [rbp - AN_DISQ], 1
    mov r13, rdx
    xor r15, r15
    jmp .an_loop
.an_name_ordinary:
    mov r13, rdx
    mov r15d, 1
    jmp .an_loop

.an_number:
    ; Digits, letters, dots and underscores, with the sign of an exponent.
    mov rdx, r13
.an_num_scan:
    cmp rdx, r12
    jae .an_num_done
    movzx eax, byte [rbx + rdx]
    cmp al, '.'
    je .an_num_next
    cmp al, '_'
    je .an_num_next
    cmp al, '0'
    jb .an_num_done
    cmp al, '9'
    jbe .an_num_next
    or al, 0x20
    cmp al, 'a'
    jb .an_num_done
    cmp al, 'z'
    ja .an_num_done
    ; an exponent takes the sign that follows it
    cmp al, 'e'
    jne .an_num_next
    lea rcx, [rdx + 1]
    cmp rcx, r12
    jae .an_num_next
    movzx eax, byte [rbx + rcx]
    cmp al, '+'
    je .an_num_exp
    cmp al, '-'
    jne .an_num_next
.an_num_exp:
    inc rdx
.an_num_next:
    inc rdx
    jmp .an_num_scan
.an_num_done:
    mov r13, rdx
    mov r15d, 1
    jmp .an_loop

.an_operator:
    movzx eax, byte [rbx + r13]
    movzx ecx, byte [rbx + r13 + 1]        ; one past is the NUL or the next
    lea rdx, [r13 + 1]
    cmp rdx, r12
    jb .an_op_have_next
    xor ecx, ecx
.an_op_have_next:

    cmp al, '.'
    je .an_op_dot
    cmp al, ','
    je .an_op_disq
    cmp al, ':'
    je .an_op_disq
    cmp al, ';'
    je .an_op_disq
    cmp al, '='
    je .an_op_disq
    cmp al, '!'
    je .an_op_disq
    cmp al, '~'
    je .an_op_unary

    cmp al, '<'
    je .an_op_lt
    cmp al, '>'
    je .an_op_gt

    ; The rest are binary only in operand position; in any other position a
    ; `+`, `-` or `*` is a unary or a star, and neither is an anchor.
    test r15, r15
    jz .an_op_unary

    cmp al, '|'
    je .an_op_or
    cmp al, '^'
    je .an_op_xor
    cmp al, '&'
    je .an_op_and
    cmp al, '+'
    je .an_op_add
    cmp al, '-'
    je .an_op_add
    cmp al, '@'
    je .an_op_mul1
    cmp al, '%'
    je .an_op_mul1
    cmp al, '/'
    je .an_op_slash
    cmp al, '*'
    je .an_op_star
    jmp .an_op_unary                       ; something else: ignore it

.an_op_dot:
    inc r13
    xor r15, r15
    jmp .an_loop

.an_op_unary:
    inc r13
    xor r15, r15
    jmp .an_loop

.an_op_disq:
    test r14, r14
    jnz .an_op_unary
    mov qword [rbp - AN_DISQ], 1
    jmp .an_op_unary

.an_op_lt:
    cmp cl, '<'
    jne .an_op_disq
    mov esi, AN_P_SHIFT
    mov edi, 2
    jmp .an_op_record
.an_op_gt:
    cmp cl, '>'
    jne .an_op_disq
    mov esi, AN_P_SHIFT
    mov edi, 2
    jmp .an_op_record
.an_op_or:
    mov esi, AN_P_OR
    mov edi, 1
    jmp .an_op_record
.an_op_xor:
    mov esi, AN_P_XOR
    mov edi, 1
    jmp .an_op_record
.an_op_and:
    mov esi, AN_P_AND
    mov edi, 1
    jmp .an_op_record
.an_op_add:
    mov esi, AN_P_ADD
    mov edi, 1
    jmp .an_op_record
.an_op_mul1:
    mov esi, AN_P_MUL
    mov edi, 1
    jmp .an_op_record
.an_op_slash:
    mov esi, AN_P_MUL
    mov edi, 1
    cmp cl, '/'
    jne .an_op_record
    mov edi, 2
    jmp .an_op_record
.an_op_star:
    cmp cl, '*'
    je .an_op_pow
    mov esi, AN_P_MUL
    mov edi, 1
    jmp .an_op_record
.an_op_pow:
    mov esi, AN_P_POW
    mov edi, 2

.an_op_record:
    ; esi = precedence, edi = operator length
    test r14, r14
    jnz .an_op_recorded            ; only depth zero is the top level
    movsxd rax, esi
    cmp rax, [rbp - AN_PREC]
    jb .an_op_take
    jne .an_op_recorded
    ; Equal precedence: the later one is the top node, because everything
    ; here associates left -- except `**`, where the first one is.
    cmp esi, AN_P_POW
    je .an_op_recorded
.an_op_take:
    mov [rbp - AN_PREC], rax
    mov [rbp - AN_IDX], r13
    movsxd rax, edi
    mov [rbp - AN_LEN], rax
.an_op_recorded:
    movsxd rax, edi
    add r13, rax
    xor r15, r15
    jmp .an_loop

.an_end:
    cmp qword [rbp - AN_DISQ], 0
    jne .an_no
    mov rax, [rbp - AN_IDX]
    test rax, rax
    jl .an_try_subscript
    mov rdx, [rbp - AN_OUT]
    mov [rdx], rax
    add rax, [rbp - AN_LEN]
    mov [rdx + 8], rax
    mov eax, 1
    jmp .an_out

.an_try_subscript:
    ; The segment is a subscript when its last character closes one.
    mov rax, [rbp - AN_SCLOSE]
    test rax, rax
    jl .an_no
    lea rcx, [rax + 1]
    cmp rcx, r12
    jne .an_no
    mov rdx, [rbp - AN_SOPEN]
    test rdx, rdx
    jle .an_no                     ; `[1, 2]` is a list, not a subscript
    mov r8, [rbp - AN_OUT]
    mov [r8], rdx
    mov [r8 + 8], rcx
    mov eax, 1
    jmp .an_out

.an_no:
    xor eax, eax
.an_out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC tb_anchors

;; tb_anchor_keyword(rdi = name, rsi = length) -> eax = 1 when the name makes
;; the segment something other than a BinOp or a Subscript.
DEF_FUNC_LOCAL tb_anchor_keyword
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    lea rcx, [rel tb_anchor_keywords]
.ak_loop:
    mov rdx, [rcx]
    test rdx, rdx
    jz .ak_no
    ; compare rsi bytes and require the table entry to end there
    xor eax, eax
.ak_cmp:
    cmp rax, r12
    jge .ak_cmp_end
    mov r8b, [rdx + rax]
    test r8b, r8b
    jz .ak_next
    cmp r8b, [rbx + rax]
    jne .ak_next
    inc rax
    jmp .ak_cmp
.ak_cmp_end:
    cmp byte [rdx + rax], 0
    je .ak_yes
.ak_next:
    add rcx, 8
    jmp .ak_loop
.ak_yes:
    mov eax, 1
    pop r12
    pop rbx
    leave
    ret
.ak_no:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
END_FUNC tb_anchor_keyword

section .rodata
tb_kw_if:     db "if", 0
tb_kw_else:   db "else", 0
tb_kw_or:     db "or", 0
tb_kw_and:    db "and", 0
tb_kw_not:    db "not", 0
tb_kw_in:     db "in", 0
tb_kw_is:     db "is", 0
tb_kw_lambda: db "lambda", 0
tb_kw_for:    db "for", 0
tb_kw_yield:  db "yield", 0
align 8
tb_anchor_keywords:
    dq tb_kw_if, tb_kw_else, tb_kw_or, tb_kw_and, tb_kw_not
    dq tb_kw_in, tb_kw_is, tb_kw_lambda, tb_kw_for, tb_kw_yield
    dq 0
section .text

;; ============================================================================
;; tb_write_source(rdi = filename str, rsi = line number, rdx = code object or
;;                 0, rcx = lasti in code units)
;; Prints the source line stripped and indented four spaces, and under it the
;; caret line, when the code object's location table says which part of the
;; line the failing instruction came from.  A file that cannot be opened
;; simply produces nothing, which is what CPython does.  The file is scanned
;; in chunks, so a large source costs no extra memory and the frame stays
;; small enough to use while unwinding.
;; ============================================================================
TS_FD    equ 8
TS_TGT   equ 16
TS_CUR   equ 24
TS_LEN   equ 32
TS_CODE  equ 40
TS_LASTI equ 48
TS_LOC   equ 88             ; four qwords: start line, end line, start, end col
TS_PATH  equ 96 + TB_PATH
TS_LBUF  equ TS_PATH + TB_LINE
TS_CBUF  equ TS_LBUF + TB_CHUNK
TS_FRAME equ TS_CBUF + 16
DEF_FUNC tb_write_source, TS_FRAME
    push rbx
    push r12
    push r13
    mov [rbp - TS_TGT], rsi
    mov [rbp - TS_CODE], rdx
    mov [rbp - TS_LASTI], rcx
    mov qword [rbp - TS_CUR], 1
    mov qword [rbp - TS_LEN], 0
    mov qword [rbp - TS_FD], -1

    test rsi, rsi
    jle .ts_out
    test rdi, rdi
    jz .ts_out
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    jne .ts_out
    mov rdx, [rdi + PyStrObject.ob_size]
    cmp rdx, TB_PATH - 1
    jae .ts_out

    ; Copy the filename into a NUL-terminated buffer for open(2)
    lea rcx, [rbp - TS_PATH]
    lea rsi, [rdi + PyStrObject.data]
    xor eax, eax
.ts_copy:
    cmp rax, rdx
    jge .ts_copied
    mov r8b, [rsi + rax]
    mov [rcx + rax], r8b
    inc rax
    jmp .ts_copy
.ts_copied:
    mov byte [rcx + rax], 0

    lea rdi, [rbp - TS_PATH]
    xor esi, esi                    ; O_RDONLY
    xor edx, edx
    call sys_open
    test eax, eax
    js .ts_out
    movsx rax, eax
    mov [rbp - TS_FD], rax

.ts_read:
    mov rdi, [rbp - TS_FD]
    lea rsi, [rbp - TS_CBUF]
    mov edx, TB_CHUNK
    call sys_read
    test rax, rax
    jle .ts_flush
    mov r12, rax                    ; bytes read
    xor rbx, rbx                    ; index
.ts_scan:
    cmp rbx, r12
    jge .ts_read
    lea rax, [rbp - TS_CBUF]
    movzx r13d, byte [rax + rbx]
    inc rbx
    cmp r13b, 10
    je .ts_newline
    mov rax, [rbp - TS_CUR]
    cmp rax, [rbp - TS_TGT]
    jne .ts_scan
    mov rax, [rbp - TS_LEN]
    cmp rax, TB_LINE - 1
    jae .ts_scan
    lea rcx, [rbp - TS_LBUF]
    mov [rcx + rax], r13b
    inc rax
    mov [rbp - TS_LEN], rax
    jmp .ts_scan
.ts_newline:
    mov rax, [rbp - TS_CUR]
    cmp rax, [rbp - TS_TGT]
    je .ts_flush
    inc rax
    mov [rbp - TS_CUR], rax
    jmp .ts_scan

.ts_flush:
    mov rax, [rbp - TS_CUR]
    cmp rax, [rbp - TS_TGT]
    jne .ts_close
    mov rdx, [rbp - TS_LEN]
    test rdx, rdx
    jz .ts_close
    ; Strip leading whitespace, then trailing.
    xor rcx, rcx
.ts_lstrip:
    cmp rcx, rdx
    jge .ts_close
    lea rax, [rbp - TS_LBUF]
    mov r8b, [rax + rcx]
    cmp r8b, ' '
    je .ts_lnext
    cmp r8b, 9
    je .ts_lnext
    cmp r8b, 13
    je .ts_lnext
    jmp .ts_lstripped
.ts_lnext:
    inc rcx
    jmp .ts_lstrip
.ts_lstripped:
.ts_rstrip:
    cmp rdx, rcx
    jle .ts_close
    lea rax, [rbp - TS_LBUF]
    mov r8b, [rax + rdx - 1]
    cmp r8b, ' '
    je .ts_rnext
    cmp r8b, 9
    je .ts_rnext
    cmp r8b, 13
    je .ts_rnext
    jmp .ts_emit
.ts_rnext:
    dec rdx
    jmp .ts_rstrip
.ts_emit:
    push rcx
    push rdx
    CSTRING rdi, "    "
    call tb_write_cstr
    pop rdx
    pop rcx
    push rcx
    lea rdi, [rbp - TS_LBUF]
    add rdi, rcx
    mov rsi, rdx
    sub rsi, rcx
    call tb_write
    CSTRING rdi, `\n`
    call tb_write_cstr
    pop rcx

    ; The caret line under it, when there is a location to draw from.
    cmp qword [rbp - TS_CODE], 0
    je .ts_close
    push rcx
    mov rdi, [rbp - TS_CODE]
    mov rsi, [rbp - TS_LASTI]
    lea rdx, [rbp - TS_LOC]
    call code_addr2location
    pop rcx
    test eax, eax
    jz .ts_close
    lea rdi, [rbp - TS_LBUF]
    mov rsi, [rbp - TS_LEN]
    mov rdx, rcx                    ; the leading whitespace we stripped
    lea rcx, [rbp - TS_LOC]
    call tb_write_carets

.ts_close:
    mov rdi, [rbp - TS_FD]
    test rdi, rdi
    jl .ts_out
    call sys_close
.ts_out:
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC tb_write_source

;; ============================================================================
;; tb_print_repeated(rdi = run length) -- the elision line CPython prints
;; ============================================================================
DEF_FUNC tb_print_repeated, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    lea rbx, [rdi - TB_RECURSIVE_CUTOFF]
    CSTRING rdi, "  [Previous line repeated "
    call tb_write_cstr
    mov rdi, rbx
    call tb_write_dec
    CSTRING rdi, " more time"
    call tb_write_cstr
    cmp rbx, 1
    je .pr_one
    CSTRING rdi, "s"
    call tb_write_cstr
.pr_one:
    CSTRING rdi, `]\n`
    call tb_write_cstr
    pop rbx
    leave
    ret
END_FUNC tb_print_repeated

;; ============================================================================
;; traceback_print_unraisable(rdi = exception, rsi = the object it came out
;;                            of, or 0)
;;
;; What CPython's _PyErr_WriteUnraisableMsg prints: a line naming the object,
;; then the exception's own report -- its traceback and its message, and
;; nothing else.  It reaches for PyTraceBack_Print rather than the display
;; routine an uncaught exception goes through, so a __cause__ or a __context__
;; is not walked here even though the exception carries one.  A generator
;; dropped inside a `finally` that raises has GeneratorExit as its context in
;; both interpreters; only this report ever showed it.  A __del__ that raises and a cleanup in a
;; dropped generator both reach it -- neither has a caller left to hand the
;; exception to, and both used to print a single line that named the kind of
;; failure and nothing else, so which object, which line and which exception
;; were all lost.
;;
;; The object is named by repr, and a repr can itself raise or recurse.  It is
;; called only when it is one of the shapes whose repr is a plain string --
;; the safe answer here is CPython's fallback, "<object repr() failed>".
;; ============================================================================
TPU_EXC   equ 8
TPU_OBJ   equ 16
TPU_FRAME equ 32            ; + 0 pushes = 32

global traceback_unraisable_default
DEF_FUNC traceback_unraisable_default, TPU_FRAME
    mov [rbp - TPU_EXC], rdi
    mov [rbp - TPU_OBJ], rsi

    CSTRING rdi, "Exception ignored in: "
    call tb_write_cstr
    mov rdi, [rbp - TPU_EXC]
    mov rsi, [rbp - TPU_OBJ]
    call tb_unraisable_name
    mov rdi, [rbp - TPU_EXC]
    mov qword [gs:ThreadState.tb_chain_suppress], 1
    call traceback_print
    mov qword [gs:ThreadState.tb_chain_suppress], 0
    leave
    ret
END_FUNC traceback_unraisable_default

;; tb_unraisable_name(rdi = the exception being reported, rsi = the object to
;; name, or 0) -- writes "<repr>\n", or a stand-in when there is no repr to
;; be had.  The exception is only there to be put back: a repr can raise.
TUN_EXC   equ 8
TUN_FRAME equ 16            ; + 0 pushes = 16
DEF_FUNC_LOCAL tb_unraisable_name, TUN_FRAME
    mov [rbp - TUN_EXC], rdi
    mov rdi, rsi
    test rdi, rdi
    jz .tpu_unknown
    extern obj_repr
    call obj_repr
    V_UNPACK rax, rdx
    cmp edx, TAG_PTR
    jne .tpu_failed
    test rax, rax
    jz .tpu_failed
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    jne .tpu_failed_ref
    push rax
    mov rdi, rax
    call tb_write_str
    pop rdi
    call obj_decref
    jmp .tpu_newline

.tpu_failed_ref:
    mov rdi, rax
    call obj_decref
.tpu_failed:
    ; A repr that raised leaves ITS exception pending; the one being reported
    ; is what matters, so put that back.
    mov rdi, [gs:ThreadState.current_exception]
    test rdi, rdi
    jz .tpu_failed_msg
    mov rax, [rbp - TUN_EXC]
    mov [gs:ThreadState.current_exception], rax
    call obj_decref
.tpu_failed_msg:
    CSTRING rdi, "<object repr() failed>"
    call tb_write_cstr
    jmp .tpu_newline

.tpu_unknown:
    CSTRING rdi, "<unknown>"
    call tb_write_cstr

.tpu_newline:
    CSTRING rdi, `\n`
    call tb_write_cstr
    leave
    ret
END_FUNC tb_unraisable_name

;; ============================================================================
;; traceback_print_unraisable(rdi = exception, rsi = the object it came out of)
;;
;; The interpreter's way in.  CPython routes this through sys.unraisablehook,
;; so a program can collect these rather than have them written to stderr --
;; which is also the only way a test can look at one, since the default report
;; names the object by repr and so carries an address.
;;
;; The hook is looked up by name every time, because the point of it is that
;; it can be replaced at any moment.  Anything that goes wrong on the way --
;; no sys module, no hook, a hook that raises -- falls back to printing, and
;; the exception the hook raised is dropped: there is nobody to give it to,
;; which is what made this an unraisable exception in the first place.
;; ============================================================================
TPH_EXC   equ 8
TPH_OBJ   equ 16
TPH_HOOK  equ 24
TPH_ARG   equ 32
TPH_SAVED equ 40
TPH_ARGV  equ 56            ; one Value
TPH_FRAME equ 72            ; + 1 push = 80, 16-aligned

global traceback_print_unraisable
DEF_FUNC traceback_print_unraisable, TPH_FRAME
    push rbx
    mov [rbp - TPH_EXC], rdi
    mov [rbp - TPH_OBJ], rsi
    mov qword [rbp - TPH_ARG], 0

    ; sys.unraisablehook, if sys is loaded and something replaced it.
    extern sys_module_obj
    mov rbx, [rel sys_module_obj]
    test rbx, rbx
    jz .tph_default
    CSTRING rdi, "unraisablehook"
    extern str_from_cstr_heap
    call str_from_cstr_heap
    push rax
    mov rdi, rbx
    mov rsi, rax
    extern obj_getattr_opt
    call obj_getattr_opt
    mov rbx, rax
    pop rdi
    call obj_decref
    test rbx, rbx
    jz .tph_default
    V_TEST_PTR rbx, rax
    ja .tph_default

    ; The default is this printer wearing a builtin's clothes; calling it
    ; would be a detour through a structseq and back.
    mov rax, [rbx + PyObject.ob_type]
    extern builtin_func_type
    lea rcx, [rel builtin_func_type]
    cmp rax, rcx
    jne .tph_call_hook
    extern sys_unraisablehook_func
    mov rax, [rbx + PyBuiltinObject.func_ptr]
    lea rcx, [rel sys_unraisablehook_func]
    cmp rax, rcx
    je .tph_drop_hook

.tph_call_hook:
    mov [rbp - TPH_HOOK], rbx
    ; The five-field structseq CPython passes.
    extern unraisable_args_type
    extern structseq_new
    extern structseq_set
    lea rdi, [rel unraisable_args_type]
    call structseq_new
    test rax, rax
    jz .tph_drop_hook
    mov [rbp - TPH_ARG], rax

    mov rdi, rax
    xor esi, esi
    mov rdx, [rbp - TPH_EXC]
    mov rdx, [rdx + PyObject.ob_type]
    INCREF rdx
    call structseq_set
    mov rdi, [rbp - TPH_ARG]
    mov esi, 1
    mov rdx, [rbp - TPH_EXC]
    INCREF rdx
    call structseq_set
    mov rdi, [rbp - TPH_ARG]
    mov esi, 2
    mov rdx, [rbp - TPH_EXC]
    mov rdx, [rdx + PyExceptionObject.exc_tb]
    test rdx, rdx
    jnz .tph_have_tb
    LOAD_NONE rdx
.tph_have_tb:
    INCREF rdx
    call structseq_set
    mov rdi, [rbp - TPH_ARG]
    mov esi, 3
    LOAD_NONE rdx
    INCREF rdx
    call structseq_set
    mov rdi, [rbp - TPH_ARG]
    mov esi, 4
    mov rdx, [rbp - TPH_OBJ]
    test rdx, rdx
    jnz .tph_have_obj
    LOAD_NONE rdx
.tph_have_obj:
    INCREF rdx
    call structseq_set

    ; The hook runs with no exception pending: it is ordinary Python, and the
    ; one being reported is an argument, not the current state.
    mov rax, [gs:ThreadState.current_exception]
    mov [rbp - TPH_SAVED], rax
    mov qword [gs:ThreadState.current_exception], 0

    mov rax, [rbp - TPH_ARG]
    mov [rbp - TPH_ARGV], rax
    mov rdi, [rbp - TPH_HOOK]
    lea rsi, [rbp - TPH_ARGV]
    mov edx, 1
    extern obj_call_n
    call obj_call_n
    push rax
    ; A hook that raises is reported against the HOOK, and the exception it
    ; was given is dropped -- CPython says "Exception ignored in
    ; sys.unraisablehook: <the hook>" and does not fall back to printing the
    ; original.  Reporting both would be reporting the same failure twice.
    mov rdi, [gs:ThreadState.current_exception]
    test rdi, rdi
    jz .tph_no_exc
    mov qword [gs:ThreadState.current_exception], 0
    push rdi
    CSTRING rdi, "Exception ignored in sys.unraisablehook: "
    call tb_write_cstr
    pop rdi
    push rdi
    mov rsi, [rbp - TPH_HOOK]
    call tb_unraisable_name
    pop rdi
    push rdi
    ; One exception, no chain -- the same rule as the default hook below.
    mov qword [gs:ThreadState.tb_chain_suppress], 1
    call traceback_print
    mov qword [gs:ThreadState.tb_chain_suppress], 0
    pop rdi
    call obj_decref
.tph_no_exc:
    mov rax, [rbp - TPH_SAVED]
    mov [gs:ThreadState.current_exception], rax
    pop rax
    test rax, rax
    jz .tph_hook_done
    V_UNPACK rax, rdx
    XDECREF_VAL rax, rdx
.tph_hook_done:
    mov rdi, [rbp - TPH_ARG]
    call obj_decref
    mov rdi, [rbp - TPH_HOOK]
    call obj_decref
    pop rbx
    leave
    ret

.tph_drop_hook:
    mov rdi, rbx
    call obj_decref
.tph_default:
.tph_print:
    mov rdi, [rbp - TPH_EXC]
    mov rsi, [rbp - TPH_OBJ]
    call traceback_unraisable_default
    pop rbx
    leave
    ret
END_FUNC traceback_print_unraisable

;; ============================================================================
;; traceback_print(rdi = exception)
;; Prints the CPython-shaped report for an uncaught exception, on stderr.
;; ============================================================================

;; ============================================================================
;; tb_print_notes(rdi = the exception) -> nothing
;;
;; PEP 678's notes, one per line, immediately after the exception line -- which
;; is where CPython's print_exception_notes puts them.  tb_print_one recurses
;; for the cause and context chain, so a note on a chained exception prints at
;; its own level with nothing further to do.
;;
;; __notes__ is read straight out of the instance dict rather than through
;; exc_getattr.  This runs while an exception is being REPORTED: a getattr walk
;; could reach a class attribute that is not this exception's, and could run
;; Python and raise a second one underneath the first.  For the same reason
;; current_exception is put back exactly as it was -- a note whose str() raises
;; is skipped, not allowed to derail the report it is part of.
;;
;; A list or a tuple is iterated; anything else is printed as its repr, which
;; is what CPython's _safe_string arrives at for the same case.  list and tuple
;; share ob_size at +16 and ob_item at +32, so one loop serves both.
;; ============================================================================
TPN_NOTES equ 8
TPN_IDX   equ 16
TPN_N     equ 24
TPN_TMP   equ 32
TPN_EXC   equ 40            ; current_exception on entry, put back on the way out
TPN_FRAME equ 48            ; + 0 pushes = 48, 16-aligned

extern list_type
extern obj_repr
extern dict_get
extern type_is_subtype

DEF_FUNC_LOCAL tb_print_notes, TPN_FRAME
    mov rax, [gs:ThreadState.current_exception]
    mov [rbp - TPN_EXC], rax
    mov qword [rbp - TPN_NOTES], 0

    mov rax, [rdi + PyExceptionObject.exc_dict]
    test rax, rax
    jz .tpn_out
    mov [rbp - TPN_TMP], rax
    CSTRING rdi, "__notes__"
    call str_from_cstr_heap
    test rax, rax
    jz .tpn_out
    mov [rbp - TPN_IDX], rax                ; the name, owned, briefly
    mov rdi, [rbp - TPN_TMP]
    mov rsi, rax
    call dict_get
    mov [rbp - TPN_NOTES], rax
    mov rdi, [rbp - TPN_IDX]
    call obj_decref

    mov rax, [rbp - TPN_NOTES]
    test rax, rax
    jz .tpn_out
    V_TEST_PTR rax, rcx
    ja .tpn_repr
    mov rdi, [rax + PyObject.ob_type]
    lea rsi, [rel list_type]
    call type_is_subtype
    test eax, eax
    jnz .tpn_seq
    mov rax, [rbp - TPN_NOTES]
    mov rdi, [rax + PyObject.ob_type]
    lea rsi, [rel tuple_type]
    call type_is_subtype
    test eax, eax
    jz .tpn_repr

.tpn_seq:
    ; A SUBCLASS of either is one, and keeps both offsets -- type_from_parts
    ; puts a subclass's own fields after tp_basicsize.  CPython iterates any
    ; sequence that is not a str or bytes; anything more exotic than these two
    ; takes the repr path here, because asking a Python __getitem__ from
    ; inside an exception report is the one thing this must not do.
    mov rax, [rbp - TPN_NOTES]
    mov rcx, [rax + PyListObject.ob_size]
    mov [rbp - TPN_N], rcx
    mov qword [rbp - TPN_IDX], 0
.tpn_loop:
    mov rcx, [rbp - TPN_IDX]
    cmp rcx, [rbp - TPN_N]
    jge .tpn_out
    mov rax, [rbp - TPN_NOTES]
    mov rax, [rax + PyListObject.ob_item]
    mov rdi, [rax + rcx*8]
    call obj_str
    V_UNPACK rax, rdx
    test rax, rax
    jz .tpn_next                            ; str() raised; skip this note
    mov [rbp - TPN_TMP], rax
    mov rdi, rax
    call tb_write_str
    mov rdi, [rbp - TPN_TMP]
    call obj_decref
    CSTRING rdi, `\n`
    call tb_write_cstr
.tpn_next:
    inc qword [rbp - TPN_IDX]
    jmp .tpn_loop

.tpn_repr:
    mov rdi, [rbp - TPN_NOTES]
    call obj_repr
    test rax, rax
    jz .tpn_out
    mov [rbp - TPN_TMP], rax
    mov rdi, rax
    call tb_write_str
    mov rdi, [rbp - TPN_TMP]
    call obj_decref
    CSTRING rdi, `\n`
    call tb_write_cstr

.tpn_out:
    mov rax, [rbp - TPN_EXC]
    mov [gs:ThreadState.current_exception], rax
    leave
    ret
END_FUNC tb_print_notes

TP_EXC   equ 8
TP_TB    equ 16
TP_TMP   equ 24
TP_LASTC equ 32          ; code object of the previous entry
TP_LASTL equ 40          ; line number of the previous entry
TP_CNT   equ 48          ; length of the current run of identical entries
TP_FRAME equ 72            ; + 1 push = 80, 16-aligned
TB_RECURSIVE_CUTOFF equ 3
DEF_FUNC traceback_print
    mov qword [gs:ThreadState.tb_seen_n], 0
    mov rsi, rdi
    xor edi, edi
    call tb_print_one
    leave
    ret
END_FUNC traceback_print

;; ============================================================================
;; tb_print_one(rsi = exception) -- the body; tb_seen guards against a cycle in
;; the __cause__ / __context__ chain, which `raise e from e` otherwise turns
;; into unbounded recursion.
;; ============================================================================
DEF_FUNC tb_print_one, TP_FRAME
    push rbx
    mov rdi, rsi
    test rdi, rdi
    jz .tp_out
    mov [rbp - TP_EXC], rdi

    ; Already reported? then this is a cycle; stop here.
    mov rcx, [gs:ThreadState.tb_seen_n]
    xor edx, edx
.tp_seen_scan:
    cmp rdx, rcx
    jge .tp_seen_add
    cmp [gs:ThreadState.tb_seen + rdx*8], rdi
    je .tp_skip
    inc rdx
    jmp .tp_seen_scan
.tp_seen_add:
    cmp rcx, TB_SEEN_MAX
    jae .tp_seen_done
    mov [gs:ThreadState.tb_seen + rcx*8], rdi
    inc rcx
    mov [gs:ThreadState.tb_seen_n], rcx
.tp_seen_done:

    ; The unraisable hook reports one exception, not a chain -- see the flag.
    cmp qword [gs:ThreadState.tb_chain_suppress], 0
    jne .tp_header

    ; A __cause__ or __context__ is reported first, then the linking sentence.
    mov rax, [rdi + PyExceptionObject.exc_cause]
    test rax, rax
    jnz .tp_cause
    ; `raise X from ...` suppresses the implicit context.
    cmp qword [rdi + PyExceptionObject.exc_suppress], 0
    jne .tp_header
    mov rax, [rdi + PyExceptionObject.exc_context]
    test rax, rax
    jz .tp_header
    mov rsi, rax
    call tb_print_one
    test eax, eax
    jz .tp_header
    CSTRING rdi, `\nDuring handling of the above exception, another exception occurred:\n\n`
    call tb_write_cstr
    jmp .tp_header
.tp_cause:
    mov rsi, rax
    call tb_print_one
    test eax, eax
    jz .tp_header
    CSTRING rdi, `\nThe above exception was the direct cause of the following exception:\n\n`
    call tb_write_cstr

.tp_header:
    mov rdi, [rbp - TP_EXC]
    mov rax, [rdi + PyExceptionObject.exc_tb]
    test rax, rax
    jz .tp_body
    mov [rbp - TP_TB], rax
    mov qword [rbp - TP_LASTC], 0
    mov qword [rbp - TP_LASTL], -1
    mov qword [rbp - TP_CNT], 0
    CSTRING rdi, `Traceback (most recent call last):\n`
    call tb_write_cstr

.tp_frame:
    mov rbx, [rbp - TP_TB]
    test rbx, rbx
    jz .tp_tail_repeat

    ; Collapse a run of identical frames the way CPython does: print the
    ; first three, then "[Previous line repeated N more times]".  Without it
    ; a RecursionError printed a thousand copies of one line.
    mov rax, [rbx + PyTracebackObject.tb_code]
    cmp rax, [rbp - TP_LASTC]
    jne .tp_newrun
    mov rax, [rbx + PyTracebackObject.tb_lineno]
    cmp rax, [rbp - TP_LASTL]
    je .tp_samerun
.tp_newrun:
    mov rdi, [rbp - TP_CNT]
    cmp rdi, TB_RECURSIVE_CUTOFF
    jle .tp_run_reset
    push rbx
    call tb_print_repeated
    pop rbx
.tp_run_reset:
    mov rax, [rbx + PyTracebackObject.tb_code]
    mov [rbp - TP_LASTC], rax
    mov rax, [rbx + PyTracebackObject.tb_lineno]
    mov [rbp - TP_LASTL], rax
    mov qword [rbp - TP_CNT], 0
.tp_samerun:
    inc qword [rbp - TP_CNT]
    cmp qword [rbp - TP_CNT], TB_RECURSIVE_CUTOFF
    jg .tp_next

    push rbx
    CSTRING rdi, `  File "`
    call tb_write_cstr
    pop rbx
    mov rax, [rbx + PyTracebackObject.tb_code]
    test rax, rax
    jz .tp_noname
    push rbx
    mov rdi, [rax + PyCodeObject.co_filename]
    call tb_write_str
    pop rbx
    push rbx
    CSTRING rdi, `", line `
    call tb_write_cstr
    pop rbx
    push rbx
    mov rdi, [rbx + PyTracebackObject.tb_lineno]
    call tb_write_dec
    pop rbx
    push rbx
    CSTRING rdi, ", in "
    call tb_write_cstr
    pop rbx
    push rbx
    mov rax, [rbx + PyTracebackObject.tb_code]
    mov rdi, [rax + PyCodeObject.co_name]
    call tb_write_str
    pop rbx
    push rbx
    CSTRING rdi, `\n`
    call tb_write_cstr
    pop rbx
    mov rax, [rbx + PyTracebackObject.tb_code]
    mov rdi, [rax + PyCodeObject.co_filename]
    mov rsi, [rbx + PyTracebackObject.tb_lineno]
    mov rdx, rax
    mov rcx, [rbx + PyTracebackObject.tb_lasti]
    push rbx
    call tb_write_source
    pop rbx
    jmp .tp_next
.tp_noname:
    push rbx
    CSTRING rdi, `?", line ?\n`
    call tb_write_cstr
    pop rbx
.tp_next:
    mov rax, [rbx + PyTracebackObject.tb_next]
    mov [rbp - TP_TB], rax
    jmp .tp_frame

.tp_tail_repeat:
    mov rdi, [rbp - TP_CNT]
    cmp rdi, TB_RECURSIVE_CUTOFF
    jle .tp_body
    call tb_print_repeated

.tp_body:
    ; A syntax error shows where it happened before it says what it was, the
    ; way CPython does: the file and line, the source of that line, and a caret
    ; under the column.  Its args carry (msg, (filename, lineno, offset, text)).
    mov rdi, [rbp - TP_EXC]
    call tb_syntax_header

    ; "TypeName: str(exc)", with the colon omitted when str(exc) is empty.
    mov rdi, [rbp - TP_EXC]
    mov rdi, [rdi + PyObject.ob_type]
    call tb_write_exc_typename

    mov rdi, [rbp - TP_EXC]
    call obj_str
    V_UNPACK rax, rdx
    test rax, rax
    jz .tp_newline
    mov [rbp - TP_TMP], rax
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    jne .tp_release
    cmp qword [rax + PyStrObject.ob_size], 0
    je .tp_release
    CSTRING rdi, ": "
    call tb_write_cstr
    mov rdi, [rbp - TP_TMP]
    call tb_write_str
.tp_release:
    mov rdi, [rbp - TP_TMP]
    call obj_decref

.tp_newline:
    CSTRING rdi, `\n`
    call tb_write_cstr
    mov rdi, [rbp - TP_EXC]
    call tb_print_notes
    mov eax, 1                      ; something was printed
    pop rbx
    leave
    ret
.tp_skip:
.tp_out:
    xor eax, eax                    ; nothing printed: NULL, or a cycle
    pop rbx
    leave
    ret
END_FUNC tb_print_one

;; ============================================================================
;; tb_write_exc_typename(rdi = an exception's type) -> nothing; written
;;
;; What traceback.py's TracebackException.format_exception_only writes: the
;; class's __qualname__, preceded by its __module__ and a dot unless that is
;; "__main__" or "builtins" -- "subprocess.CalledProcessError",
;; "json.decoder.JSONDecodeError", plain "ValueError".  Either attribute not
;; being a str falls back to the bare tp_name, as the plain name was before.
;; ============================================================================
TWN_TYPE  equ 8
TWN_KEY   equ 16
TWN_MOD   equ 24
TWN_QUAL  equ 32
TWN_FRAME equ 32
DEF_FUNC_LOCAL tb_write_exc_typename, TWN_FRAME
    mov [rbp - TWN_TYPE], rdi
    mov qword [rbp - TWN_MOD], 0
    mov qword [rbp - TWN_QUAL], 0
    CSTRING rdi, "__qualname__"
    call twn_get_str
    mov [rbp - TWN_QUAL], rax
    test rax, rax
    jz .twn_plain
    CSTRING rdi, "__module__"
    call twn_get_str
    mov [rbp - TWN_MOD], rax
    test rax, rax
    jz .twn_qual
    lea rdi, [rax + PyStrObject.data]
    CSTRING rsi, "__main__"
    call ap_strcmp
    test eax, eax
    jz .twn_qual
    mov rax, [rbp - TWN_MOD]
    lea rdi, [rax + PyStrObject.data]
    CSTRING rsi, "builtins"
    call ap_strcmp
    test eax, eax
    jz .twn_qual
    mov rdi, [rbp - TWN_MOD]
    call tb_write_str
    CSTRING rdi, "."
    call tb_write_cstr
.twn_qual:
    mov rdi, [rbp - TWN_QUAL]
    call tb_write_str
    jmp .twn_release
.twn_plain:
    mov rax, [rbp - TWN_TYPE]
    mov rdi, [rax + PyTypeObject.tp_name]
    call tb_write_cstr
.twn_release:
    mov rdi, [rbp - TWN_MOD]
    test rdi, rdi
    jz .twn_no_mod
    call obj_decref
.twn_no_mod:
    mov rdi, [rbp - TWN_QUAL]
    test rdi, rdi
    jz .twn_out
    call obj_decref
.twn_out:
    leave
    ret

;; twn_get_str(rdi = attribute name C string) -> rax = that attribute of
;; [rbp - TWN_TYPE] when it is an exact str, owned, else 0.  A local
;; subroutine on tb_write_exc_typename's frame, reached by `call` from it.
twn_get_str:
    sub rsp, 8
    call str_from_cstr_heap
    mov [rbp - TWN_KEY], rax
    mov rdi, [rbp - TWN_TYPE]
    mov rsi, rax
    extern obj_getattr_opt
    call obj_getattr_opt
    push rax
    sub rsp, 8
    mov rdi, [rbp - TWN_KEY]
    call obj_decref
    add rsp, 8
    pop rax
    test rax, rax
    jz .tgs_out
    V_TEST_PTR rax, rcx
    ja .tgs_drop
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    je .tgs_out
.tgs_drop:
    mov rdi, rax
    DECREF_V rdi, rcx
    xor eax, eax
.tgs_out:
    add rsp, 8
    ret
END_FUNC tb_write_exc_typename

;; ============================================================================
;; tb_syntax_header(PyObject *exc)
;; The File/line/source/caret block a syntax error is printed with.  Does
;; nothing for anything else, or for a syntax error with no location.
;; ============================================================================
SH_INNER equ 16
SH_TEXT  equ 24
SH_COL   equ 32
SH_I     equ 40
SH_LEN   equ 48           ; bytes of source text actually written
SH_HASCOL equ 56          ; whether args[1][2] gave us a usable column
SH_FRAME equ 72           ; + 1 push = 80
DEF_FUNC tb_syntax_header, SH_FRAME
    push rbx
    mov rbx, rdi
    call exc_is_syntax
    test eax, eax
    jz .done

    ; args is whatever the raise supplied, so every step has to be checked:
    ; `raise SyntaxError("m", (1, 2, 3, 4))` is legal Python and would
    ; otherwise print the integer 1 as if it were a filename string.
    mov rax, [rbx + PyExceptionObject.exc_args]
    V_TEST_PTR rax, rcx
    ja .done
    test rax, rax
    jz .done
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel tuple_type]
    cmp rcx, rdx
    jne .done
    cmp qword [rax + PyTupleObject.ob_size], 2
    jl .done
    mov rax, [rax + PyTupleObject.ob_item]
    mov rax, [rax + 8]
    V_TEST_PTR rax, rcx
    ja .done
    test rax, rax
    jz .done
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel tuple_type]
    cmp rcx, rdx
    jne .done
    cmp qword [rax + PyTupleObject.ob_size], 4
    jl .done
    mov [rbp - SH_INNER], rax
    mov rax, [rax + PyTupleObject.ob_item]

    ; The filename must be a str and the line number an int.
    mov rcx, [rax]
    V_TEST_PTR rcx, rdx
    ja .done
    test rcx, rcx
    jz .done
    mov rdx, [rcx + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rdx, rcx
    jne .done
    mov rcx, [rax + 8]
    V_IS_INT rcx, rdx
    jb .done

    push rax
    CSTRING rdi, `  File "`
    call tb_write_cstr
    pop rax
    push rax
    mov rdi, [rax]
    call tb_write_str
    pop rax
    push rax
    CSTRING rdi, `", line `
    call tb_write_cstr
    pop rax
    push rax
    mov rdi, [rax + 8]
    V_TO_I64 rdi
    call tb_write_dec
    pop rax
    push rax
    CSTRING rdi, `\n`
    call tb_write_cstr
    pop rax

    ; The source line, indented four spaces and stripped of leading blanks the
    ; way CPython prints it, then a caret under the offending column.
    mov rcx, [rax + 24]
    mov [rbp - SH_TEXT], rcx
    ; The offset is checked like the line number is.  It is legally None --
    ; that is what CPython puts there when the column is unknown -- and None is
    ; a heap pointer, so subtracting the int bias from it gave about 2^50 and
    ; the caret loop below wrote that many spaces, one write() each.
    mov rcx, [rax + 16]
    mov qword [rbp - SH_HASCOL], 1
    V_IS_INT rcx, rdx
    jae .have_col
    ; No usable column: CPython prints the source line and no caret at all.
    mov qword [rbp - SH_HASCOL], 0
    xor ecx, ecx
    jmp .stash_col
.have_col:
    V_TO_I64 rcx
.stash_col:
    mov [rbp - SH_COL], rcx
    mov rax, [rbp - SH_TEXT]
    V_TEST_PTR rax, rcx
    ja .done
    test rax, rax
    jz .done
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    jne .done

    ; Skip the leading whitespace, and take the caret's column with it.
    xor ecx, ecx
.skip:
    cmp rcx, [rax + PyStrObject.ob_size]
    jae .have_skip
    mov dl, [rax + PyStrObject.data + rcx]
    cmp dl, ' '
    je .skip_next
    cmp dl, 9
    jne .have_skip
.skip_next:
    inc rcx
    jmp .skip
.have_skip:
    mov [rbp - SH_I], rcx

    push rax
    CSTRING rdi, "    "
    call tb_write_cstr
    pop rax
    mov rdi, rax
    add rdi, PyStrObject.data
    add rdi, [rbp - SH_I]
    mov rsi, [rax + PyStrObject.ob_size]
    sub rsi, [rbp - SH_I]
    mov qword [rbp - SH_LEN], 0
    ; Trim the trailing newline; the caret line supplies its own.
    test rsi, rsi
    jle .no_text
    cmp byte [rdi + rsi - 1], 10
    jne .write_text
    dec rsi
.write_text:
    mov [rbp - SH_LEN], rsi
    call tb_write
    CSTRING rdi, `\n`
    call tb_write_cstr
.no_text:

    ; The caret, under the column.  The offset is one-based and the leading
    ; whitespace has already been dropped, so both come off it.
    cmp qword [rbp - SH_HASCOL], 0
    je .done
    CSTRING rdi, "    "
    call tb_write_cstr
    mov rcx, [rbp - SH_COL]
    dec rcx
    sub rcx, [rbp - SH_I]
    jns .pad
    xor ecx, ecx
.pad:
    ; A caret past the end of the line is not a caret.  args[1][2] is whatever
    ; the raiser put there -- a Python program may raise SyntaxError with any
    ; offset it likes -- and the loop below writes one space per column.
    cmp rcx, [rbp - SH_LEN]
    jbe .pad_ok
    mov rcx, [rbp - SH_LEN]
.pad_ok:
    mov [rbp - SH_I], rcx
.pad_loop:
    cmp qword [rbp - SH_I], 0
    jle .caret
    CSTRING rdi, " "
    call tb_write_cstr
    dec qword [rbp - SH_I]
    jmp .pad_loop
.caret:
    CSTRING rdi, `^\n`
    call tb_write_cstr
.done:
    pop rbx
    leave
    ret
END_FUNC tb_syntax_header


;; ============================================================================
;; (was src/except.asm)
;; ============================================================================

section .text

;; ============================================================================
;; exc_table_find_handler(PyCodeObject *code, int bytecode_offset_halfwords)
;; -> rax = handler target (in halfwords), rdx = stack depth, rcx = push_lasti
;; -> rax = -1 if no handler found
;;
;; bytecode_offset_halfwords = (rbx - &code.co_code) / 2
;;
;; rdi = code object
;; esi = bytecode offset in instruction units (halfwords, i.e., 2-byte units)
;; ============================================================================
DEF_FUNC exc_table_find_handler, 8            ; 5 pushes, so rsp is 16-aligned
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov r12d, esi           ; r12d = target offset (in instruction units)

    ; Get co_exceptiontable (PyBytesObject*)
    mov rax, [rdi + PyCodeObject.co_exceptiontable]
    test rax, rax
    jz .not_found

    ; Get table data pointer and size
    mov r13, [rax + PyBytesObject.ob_size]  ; r13 = table length
    test r13, r13
    jz .not_found
    lea r14, [rax + PyBytesObject.data]     ; r14 = table data start
    xor r15d, r15d                          ; r15 = current position in table

.scan_entry:
    cmp r15, r13
    jge .not_found

    ; Read start (unsigned varint)
    call .read_varint
    mov ebx, eax            ; ebx = start

    ; Read length (unsigned varint)
    ; NOTE: .read_varint clobbers ecx/esi, so use r8/r9 for length/target
    call .read_varint
    mov r8d, eax            ; r8d = length (safe from .read_varint)

    ; Read target (unsigned varint)
    call .read_varint
    mov r9d, eax            ; r9d = target (safe from .read_varint)

    ; Read depth_lasti (unsigned varint)
    call .read_varint
    ; eax = depth_lasti: depth = eax >> 1, push_lasti = eax & 1
    mov edi, eax            ; edi = depth_lasti

    ; Check if bytecode_offset is in range [start, start+length)
    cmp r12d, ebx
    jb .scan_entry           ; offset < start, try next
    lea edx, [ebx + r8d]    ; edx = start + length
    cmp r12d, edx
    jge .scan_entry          ; offset >= start + length, try next

    ; Found a matching handler!
    ; Return: rax = target, edx = depth, ecx = push_lasti
    mov eax, r9d            ; handler target in instruction units
    mov ecx, edi
    and ecx, 1              ; push_lasti flag
    shr edi, 1
    mov edx, edi            ; stack depth

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.not_found:
    mov rax, -1
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

; Internal: read an unsigned varint from table at r14+r15
; Returns value in eax, advances r15
; Big-endian 6-bit chunks: first byte = high bits, bit 6 = continue
; Algorithm: val = b & 63; while (b & 64) { val <<= 6; b = next; val |= b & 63; }
.read_varint:
    cmp r15, r13
    jge .varint_zero         ; safety: don't read past end
    movzx edx, byte [r14 + r15]
    inc r15
    mov eax, edx
    and eax, 0x3f           ; initial value = bits 0-5 of first byte

.varint_loop:
    test edx, 0x40          ; check continue bit
    jz .varint_done
    cmp r15, r13
    jge .varint_done         ; safety
    shl eax, 6              ; shift accumulated value LEFT
    movzx edx, byte [r14 + r15]
    inc r15
    mov ecx, edx
    and ecx, 0x3f
    or eax, ecx             ; OR in new 6 bits at bottom
    jmp .varint_loop

.varint_zero:
    xor eax, eax
.varint_done:
    ret
END_FUNC exc_table_find_handler
