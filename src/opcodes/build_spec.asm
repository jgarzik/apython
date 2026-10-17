; opcodes/build_spec.asm - the specialized container and iteration opcodes
;
; Handlers that a generic opcode rewrites itself into once it has seen the
; shape of its operands.  Each guards that shape, does the work inline, and on
; a guard failure writes the generic opcode byte back and enters the generic
; handler.
;
;   213  FOR_ITER_LIST              a for-loop over a list
;   214  FOR_ITER_RANGE             a for-loop over a range
;   235  BINARY_SUBSCR_LIST_INT     lst[i]
;   236  BINARY_SUBSCR_TUPLE_INT    tup[i]
;   237  STORE_SUBSCR_LIST_INT      lst[i] = v
;   238  UNPACK_SEQUENCE_TUPLE      a, b = tup
;   239  UNPACK_SEQUENCE_LIST       a, b = lst
;
; Split out of build.asm, which keeps the generic handlers and the error
; messages, because that file had 3.5k left under lint's 100k cap for a
; hand-written file -- not enough for the subscript and unpack specializations
; that belong beside these.  Same seam as arith.asm/arith_spec.asm and
; load.asm/load_ic.asm: nothing here calls a file-local helper of the file it
; came from.
;
; FOR_ITER carries a jump offset that can be preceded by an EXTENDED_ARG, so
; the deopts here jump to op_for_iter with ecx intact rather than rewinding
; rbx by two -- rewinding would land past the prefix and read the low byte of
; the offset as the whole of it, jumping into the middle of the loop body on
; exhaustion.  op_for_iter_list keeps the offset on the machine stack because
; it uses rcx as its loop index, and each of its three exits has to dispose of
; that push.

%include "macros.inc"
%include "object.inc"
%include "opcodes.inc"

extern opcode_dispatch_table
extern obj_dealloc
extern obj_decref
extern list_iter_type
extern range_iter_type
extern list_type
extern tuple_type
extern op_for_iter
extern op_binary_subscr
extern op_store_subscr
extern op_unpack_sequence

section .text

;; ============================================================================
;; op_for_iter_range (214) -> nothing; pushes the next item, or jumps past
;;   the loop body when the range is exhausted
;;
;; Guard: TOS ob_type == range_iter_type.  Inlines range_iter_next -- decode
;; current/stop/step, check bounds, push the immediate, advance current -- so
;; an ordinary counting loop makes no call at all.
;;
;; ecx = jump offset. Followed by 1 CACHE entry (2 bytes).
;; ============================================================================
DEF_FUNC_BARE op_for_iter_range
    VPEEK rdi                      ; iterator (don't pop)
    ; Guard: must be range_iter_type
    lea rax, [rel range_iter_type]
    cmp [rdi + PyObject.ob_type], rax
    jne .fir_deopt

    ; Inline range_iter_next
    mov rax, [rdi + PyRangeIterObject.it_current]

    mov r8, [rdi + PyRangeIterObject.it_stop]

    mov r9, [rdi + PyRangeIterObject.it_step]

    ; Check exhaustion
    test r9, r9
    js .fir_neg_step
    ; Positive step: current >= stop -> exhausted
    cmp rax, r8
    jge .fir_exhausted
    jmp .fir_has_value
.fir_neg_step:
    ; Negative step: current <= stop -> exhausted
    cmp rax, r8
    jle .fir_exhausted

.fir_has_value:
    ; Return current as SmallInt (no INCREF needed for SmallInt)
    mov rdx, rax

    ; Advance: current += step.  A SIGNED overflow means the next value is
    ; past anything an int64 holds, so the run is over; saturating at stop
    ; makes the next pass report exhaustion.  range_iter_next has had this
    ; guard since `range(2**63-2, 2**63-1, 2)` looped for ever, and this copy
    ; of it did not -- so `for i in range(1, 256, sys.maxsize)` was right
    ; until the site specialised and wrong on every pass after.
    add rax, r9
    jno .fir_no_overflow
    mov rax, r8
.fir_no_overflow:
    mov [rdi + PyRangeIterObject.it_current], rax

    VPUSH_INT rdx, r15                  ; push value
    add rbx, 2                     ; skip CACHE
    DISPATCH

.fir_exhausted:
    ; Pop iterator, skip CACHE + jump by (arg + 1)
    ; ecx = saved arg (from instruction word)
    lea rcx, [rcx + 1]            ; arg + 1
    add rbx, 2                     ; skip CACHE
    lea rbx, [rbx + rcx*2]        ; jump forward
    VPOP rdi
    DECREF_V rdi, rsi
    DISPATCH

.fir_deopt:
    ; Type mismatch: rewrite to FOR_ITER (93) and run the generic handler.
    ;
    ; NOT by rewinding rbx and re-dispatching.  A FOR_ITER whose jump offset
    ; is over 255 is preceded by EXTENDED_ARG, and rewinding two bytes lands
    ; on the FOR_ITER alone: the prefix is gone, so the re-execution takes the
    ; low byte of the offset as the whole of it and, on exhaustion, jumps into
    ; the middle of its own loop body.  ecx already holds the full argument,
    ; so entering the generic handler directly is both correct and cheaper.
    mov byte [rbx - 2], 93
    jmp op_for_iter
END_FUNC op_for_iter_range

;; ============================================================================
;; op_for_iter_list (213) -> nothing; pushes the next item, or jumps past the
;;   loop body when the list is exhausted
;;
;; Guard: TOS ob_type == list_iter_type.  Inlines list_iter_next -- bounds
;; check against ob_size, load the item, INCREF, advance the index.
;;
;; ecx = jump offset, and it is kept on the machine stack because rcx is this
;; handler's loop index.  All three exits -- hit, exhausted and deopt -- have
;; to dispose of that one push, and they do it three different ways.
;;
;; Followed by 1 CACHE entry (2 bytes).
;; ============================================================================
DEF_FUNC_BARE op_for_iter_list
    push rcx                       ; save jump offset (ecx will be clobbered)
    VPEEK rdi                      ; iterator (don't pop)
    ; Guard: must be list_iter_type
    lea rax, [rel list_iter_type]
    cmp [rdi + PyObject.ob_type], rax
    jne .fil_deopt

    ; Inline list_iter_next
    mov rax, [rdi + PyListIterObject.it_seq]       ; list ptr
    ; ...including the test it opens with.  An iterator that has already run
    ; out has had it_seq CLEARED -- .fil_exhausted below does it, so that a
    ; __del__ re-entering the iterator finds it empty rather than pointing at
    ; storage being freed -- and reading ob_size off that NULL is a
    ; dereference of address zero.  Two `for` loops over one iterator is all it
    ; takes, and itertools.dropwhile is written exactly that way.
    test rax, rax
    jz .fil_exhausted
    mov rcx, [rdi + PyListIterObject.it_index]     ; current index

    ; Check bounds
    cmp rcx, [rax + PyListObject.ob_size]
    jge .fil_exhausted

    ; Get item and INCREF (payload + tag arrays)
    ; A list slot already holds a Value.  This used to V_UNPACK it into a
    ; (payload, tag) pair and V_PACK it straight back around the refcount
    ; bump, which made the SPECIALIZATION slower at handling the value than
    ; the generic list_iter_next it exists to beat -- that one has always
    ; been two instructions here.
    mov rdx, [rax + PyListObject.ob_item]
    mov rax, [rdx + rcx * 8]      ; the item Value
    INCREF_V rax, rdx

    ; Advance index
    inc qword [rdi + PyListIterObject.it_index]

    add rsp, 8                     ; discard saved jump offset
    VPUSH rax
    add rbx, 2                     ; skip CACHE
    DISPATCH

.fil_exhausted:
    ; Clear it_seq BEFORE releasing the list, for the reason list_iter_next
    ; carries in full: a __del__ that re-enters this iterator must find it
    ; exhausted rather than pointing at storage being freed.
    push rdi                       ; save iterator ptr
    mov rdi, [rdi + PyListIterObject.it_seq]
    mov rcx, [rsp]
    mov qword [rcx + PyListIterObject.it_seq], 0
    test rdi, rdi
    jz .fil_already_exhausted
    call obj_decref
.fil_already_exhausted:
    pop rdi

    ; Restore the original arg (jump offset)
    pop rcx                        ; restore jump offset
    lea rcx, [rcx + 1]            ; arg + 1
    add rbx, 2                     ; skip CACHE
    lea rbx, [rbx + rcx*2]        ; jump forward
    VPOP rdi
    DECREF_V rdi, rsi
    DISPATCH

.fil_deopt:
    pop rcx                        ; restore the full jump offset
    ; Rewrite to FOR_ITER (93) and enter the generic handler with it -- see
    ; .fir_deopt above for why rewinding rbx instead would be wrong.
    mov byte [rbx - 2], 93
    jmp op_for_iter
END_FUNC op_for_iter_list


;; ============================================================================
;; The subscript specializations
;;
;; A list and a tuple have ob_size at +16 and ob_item at +32 alike, so one
;; body serves both and the two handlers differ only in the type they compare
;; against.  BSUB_INT_BODY generates them.
;;
;; What they replace is not one call but two: op_binary_subscr reaches
;; list_subscript through tp_as_mapping->mp_subscript, and list_subscript
;; calls list_getitem, each with a full prologue, either side of four machine
;; pushes and a V_PACK/V_UNPACK round trip on the key.  A guarded inline read
;; is about a dozen instructions and no call at all.
;;
;; BINARY_SUBSCR and STORE_SUBSCR carry no oparg -- op_meta gives neither
;; OM_HASARG -- so neither can ever be preceded by an EXTENDED_ARG, and the
;; cheap deopt is available: write the generic opcode byte back, rewind rbx by
;; the two bytes DISPATCH advanced it, and re-dispatch.  Nothing is popped
;; before a deopt can be taken, so there is nothing to put back.
;;
;; An index out of range deopts rather than raising here.  The generic handler
;; owns the IndexError and its wording, and a site that goes out of range is a
;; site that is about to raise anyway.
;; ============================================================================

%macro BSUB_INT_BODY 2          ; %1 = handler name, %2 = type symbol
DEF_FUNC_BARE %1
    mov rax, [r13 - 8]              ; the key Value
    V_IS_INT rax, rdx
    jb %%deopt
    mov rdi, [r13 - 16]             ; the container Value
    V_TEST_PTR rdi, rdx
    ja %%deopt
    lea rdx, [rel %2]
    cmp [rdi + PyObject.ob_type], rdx
    jne %%deopt

    V_TO_I64 rax                    ; rax = the index, as a plain int64
    mov rdx, [rdi + PyListObject.ob_size]
    test rax, rax
    jns %%nonneg
    add rax, rdx                    ; a negative index counts from the end
%%nonneg:
    cmp rax, rdx
    jae %%deopt                     ; unsigned, so it catches a still-negative
                                    ; index as well as one past the end

    mov rdx, [rdi + PyListObject.ob_item]
    mov rax, [rdx + rax*8]          ; the item, already a Value
    INCREF_V rax, rdx

    ; The container's own reference goes away with its stack slot.  The item
    ; is INCREFd above the drop, so it survives even when the container was
    ; the last thing holding it -- `f()[0]` is exactly that shape.  It has to
    ; sit in a callee-saved register meanwhile: DECREF_V calls obj_dealloc
    ; when the count reaches zero, and that clobbers every caller-saved one.
    mov r15, rax
    DECREF_V rdi, rdx
    VREPLACE2 r15

    add rbx, 2                      ; skip 1 CACHE entry
    DISPATCH

%%deopt:
    mov byte [rbx - 2], OP_BINARY_SUBSCR
    sub rbx, 2
    DISPATCH
END_FUNC %1
%endmacro

;; ============================================================================
;; op_binary_subscr_list_int (235) -> nothing; replaces the pair with the item
;; ============================================================================
BSUB_INT_BODY op_binary_subscr_list_int, list_type

;; ============================================================================
;; op_binary_subscr_tuple_int (236) -> nothing; replaces the pair with the item
;; ============================================================================
BSUB_INT_BODY op_binary_subscr_tuple_int, tuple_type

;; ============================================================================
;; op_store_subscr_list_int (237) -> nothing; stores and pops all three
;;
;; Stack on entry, top last:  value, container, key.
;;
;; The new value is not INCREFd: the stack was holding a reference to it and
;; the list takes that one over.  The old occupant is released afterwards, and
;; the store happens BEFORE the release, because a __del__ reached from it can
;; run arbitrary code -- including code that reallocates ob_item, which would
;; leave the address computed here pointing into a freed block.
;; ============================================================================
DEF_FUNC_BARE op_store_subscr_list_int
    mov rax, [r13 - 8]              ; the key Value
    V_IS_INT rax, rdx
    jb .ssl_deopt
    mov rdi, [r13 - 16]             ; the container Value
    V_TEST_PTR rdi, rdx
    ja .ssl_deopt
    lea rdx, [rel list_type]
    cmp [rdi + PyObject.ob_type], rdx
    jne .ssl_deopt

    V_TO_I64 rax
    mov rdx, [rdi + PyListObject.ob_size]
    test rax, rax
    jns .ssl_nonneg
    add rax, rdx
.ssl_nonneg:
    cmp rax, rdx
    jae .ssl_deopt

    mov rdx, [rdi + PyListObject.ob_item]
    lea rcx, [rdx + rax*8]          ; the slot
    mov rsi, [r13 - 24]             ; the new value, owned by the stack
    mov rax, [rcx]                  ; the old occupant, owned by the list
    mov [rcx], rsi                  ; the list takes the stack's reference

    sub r13, 24                     ; all three operands are consumed

    ; Both drops can call obj_dealloc, so the container is parked in a
    ; callee-saved register across the first of them.
    mov r15, rdi
    DECREF_V rax, rdx               ; the value that was there
    DECREF_V r15, rdx               ; the container's stack reference

    add rbx, 2                      ; skip 1 CACHE entry
    DISPATCH

.ssl_deopt:
    mov byte [rbx - 2], OP_STORE_SUBSCR
    sub rbx, 2
    DISPATCH
END_FUNC op_store_subscr_list_int


;; ============================================================================
;; The unpack specializations
;;
;; UNPACK_SEQUENCE's generic handler decides between tuple, list, str and
;; "anything else iterable" with a type ladder, keeps three words on the
;; machine stack so that the materialising path has somewhere to put the tuple
;; it builds, and unwinds all of that on the way out.  A tuple or a list of
;; exactly the right length needs none of it: the item array is already a
;; Value array of the right shape, and the fill is the whole instruction.
;;
;; UNPACK_SEQUENCE carries an oparg -- the count -- and a count over 255 is
;; preceded by an EXTENDED_ARG, whose contribution exists only in ecx.  So the
;; deopt jumps to the generic handler with ecx intact rather than rewinding
;; rbx, and nothing before the last guard may touch rcx.
;;
;; A length mismatch deopts.  The generic handler owns the ValueError and both
;; of its wordings, and -- the part that matters -- owns the rule that the
;; sequence is NOT released on that path, because the unwinder restores r13 to
;; where it stood before the instruction and releases the slot itself.
;; ============================================================================

%macro UNPACK_SEQ_BODY 3        ; %1 = handler, %2 = type symbol, %3 = size field
DEF_FUNC_BARE %1
    mov rdi, [r13 - 8]              ; the sequence Value, not yet popped
    V_TEST_PTR rdi, rdx
    ja %%deopt
    lea rdx, [rel %2]
    cmp [rdi + PyObject.ob_type], rdx
    jne %%deopt
    cmp rcx, [rdi + %3]             ; ecx is the expected count
    jne %%deopt

    ; Past the last guard, so rcx is free.
    mov rsi, [rdi + PyListObject.ob_item]
    mov r10, rcx
    neg r10                         ; the fill writes backwards from the top
    lea r13, [r13 + rcx*8 - 8]      ; the sequence slot goes, count slots come
    dec ecx                         ; source index, count-1 down to 0

    ; items[count-1] lands deepest and items[0] on top, so that the first
    ; assignment target pops the first element.
%%fill:
    test ecx, ecx
    js %%done
    mov eax, ecx
    mov rax, [rsi + rax*8]
    INCREF_V rax, rdx
    mov [r13 + r10*8], rax
    inc r10
    dec ecx
    jmp %%fill

%%done:
    ; Every item is INCREFd above, so the sequence can go even when it was the
    ; last thing holding them.
    DECREF_V rdi, rdx
    add rbx, 2                      ; skip 1 CACHE entry
    DISPATCH

%%deopt:
    mov byte [rbx - 2], OP_UNPACK_SEQUENCE
    jmp op_unpack_sequence
END_FUNC %1
%endmacro

;; ============================================================================
;; op_unpack_sequence_tuple (238) -> nothing; replaces the tuple with its items
;; ============================================================================
UNPACK_SEQ_BODY op_unpack_sequence_tuple, tuple_type, PyTupleObject.ob_size

;; ============================================================================
;; op_unpack_sequence_list (239) -> nothing; replaces the list with its items
;; ============================================================================
UNPACK_SEQ_BODY op_unpack_sequence_list, list_type, PyListObject.ob_size
