; compiler.inc - Shared definitions for the Python source compiler
;
; The compiler turns Python 3.12 source into a PyCodeObject that apython's own
; eval loop runs.  Pipeline:
;
;   source -> lex.asm    -> Token[]      (whole file, materialized)
;          -> parse.asm  -> AstNode[]    (32-byte nodes, u32 indices)
;          -> symtab.asm -> Scope[]      (bindings classified local/global/cell/free)
;          -> codegen.asm-> Instr[]      (flat, labels unresolved)
;          -> assemble.asm-> PyCodeObject
;
; THE CARDINAL RULE OF THIS SUBSYSTEM: no function here may call
; raise_exception.  That function tail-jumps into eval_exception_unwind, which
; calls fatal_error when there is no live interpreter frame -- and compiling
; `./apython foo.py` from main.asm has no frame at all.  Errors are reported
; with comp_error(), which records the exception and RETURNS; callers propagate
; 0/NULL upward until compile_source() tears down its arenas and hands the
; pending exception to its caller.

%ifndef COMPILER_INC
%define COMPILER_INC

;; ===========================================================================
;; Token kinds.  Dense and below 128 so the Pratt table can be a flat array
;; indexed by kind.
;; ===========================================================================

TOK_ENDMARKER   equ 0
TOK_NEWLINE     equ 1
TOK_INDENT      equ 2
TOK_DEDENT      equ 3
TOK_NAME        equ 4
TOK_NUMBER      equ 5
TOK_STRING      equ 6
TOK_FSTRING     equ 7

; Delimiters and operators.  Order is not significant, density is.
TOK_LPAR             equ 8    ; (
TOK_RPAR             equ 9    ; )
TOK_LSQB             equ 10   ; [
TOK_RSQB             equ 11   ; ]
TOK_LBRACE           equ 12   ; {
TOK_RBRACE           equ 13   ; }
TOK_COLON            equ 14   ; :
TOK_COMMA            equ 15   ; ,
TOK_SEMI             equ 16   ; ;
TOK_DOT              equ 17   ; .
TOK_ELLIPSIS         equ 18   ; ...
TOK_PLUS             equ 19   ; +
TOK_MINUS            equ 20   ; -
TOK_STAR             equ 21   ; *
TOK_DOUBLESTAR       equ 22   ; **
TOK_SLASH            equ 23   ; /
TOK_DOUBLESLASH      equ 24   ; //
TOK_PERCENT          equ 25   ; %
TOK_AT               equ 26   ; @
TOK_VBAR             equ 27   ; |
TOK_AMPER            equ 28   ; &
TOK_CIRCUMFLEX       equ 29   ; ^
TOK_TILDE            equ 30   ; ~
TOK_LEFTSHIFT        equ 31   ; <<
TOK_RIGHTSHIFT       equ 32   ; >>
TOK_LESS             equ 33   ; <
TOK_GREATER          equ 34   ; >
TOK_LESSEQUAL        equ 35   ; <=
TOK_GREATEREQUAL     equ 36   ; >=
TOK_EQEQUAL          equ 37   ; ==
TOK_NOTEQUAL         equ 38   ; !=
TOK_EQUAL            equ 39   ; =
TOK_COLONEQUAL       equ 40   ; :=
TOK_RARROW           equ 41   ; ->
TOK_PLUSEQUAL        equ 42   ; +=
TOK_MINEQUAL         equ 43   ; -=
TOK_STAREQUAL        equ 44   ; *=
TOK_DOUBLESTAREQUAL  equ 45   ; **=
TOK_SLASHEQUAL       equ 46   ; /=
TOK_DOUBLESLASHEQUAL equ 47   ; //=
TOK_PERCENTEQUAL     equ 48   ; %=
TOK_ATEQUAL          equ 49   ; @=
TOK_VBAREQUAL        equ 50   ; |=
TOK_AMPEREQUAL       equ 51   ; &=
TOK_CIRCUMFLEXEQUAL  equ 52   ; ^=
TOK_LEFTSHIFTEQUAL   equ 53   ; <<=
TOK_RIGHTSHIFTEQUAL  equ 54   ; >>=

; Keywords.  TOK_KW_FIRST..TOK_KW_LAST is a contiguous run so the lexer can
; test "is this token a keyword" with two compares.
TOK_KW_FIRST    equ 55
TOK_FALSE       equ 55
TOK_NONE        equ 56
TOK_TRUE        equ 57
TOK_AND         equ 58
TOK_AS          equ 59
TOK_ASSERT      equ 60
TOK_ASYNC       equ 61
TOK_AWAIT       equ 62
TOK_BREAK       equ 63
TOK_CLASS       equ 64
TOK_CONTINUE    equ 65
TOK_DEF         equ 66
TOK_DEL         equ 67
TOK_ELIF        equ 68
TOK_ELSE        equ 69
TOK_EXCEPT      equ 70
TOK_FINALLY     equ 71
TOK_FOR         equ 72
TOK_FROM        equ 73
TOK_GLOBAL      equ 74
TOK_IF          equ 75
TOK_IMPORT      equ 76
TOK_IN          equ 77
TOK_IS          equ 78
TOK_LAMBDA      equ 79
TOK_NONLOCAL    equ 80
TOK_NOT         equ 81
TOK_OR          equ 82
TOK_PASS        equ 83
TOK_RAISE       equ 84
TOK_RETURN      equ 85
TOK_TRY         equ 86
TOK_WHILE       equ 87
TOK_WITH        equ 88
TOK_YIELD       equ 89
TOK_KW_LAST     equ 89

; A `# type:` comment, emitted only when PyCF_TYPE_COMMENTS asked for one.
; The token's span covers the text AFTER the colon, with the leading blanks
; already dropped -- which is what ast.parse reports.
TOK_TYPE_COMMENT equ 90

; `# type: ignore` and `# type: ignore[code]`.  CPython does not attach these
; to a statement; it collects them on the Module as TypeIgnore(lineno, tag),
; where the tag is whatever followed the word.
TOK_TYPE_IGNORE  equ 91

TOK_COUNT       equ 92

; Token.flags bits
TF_SOFT_MATCH   equ 0x0001   ; the NAME is literally "match"
TF_SOFT_CASE    equ 0x0002   ; ... "case"
TF_SOFT_TYPE    equ 0x0004   ; ... "type"
TF_SOFT_UNDER   equ 0x0008   ; ... "_"
TF_STR_RAW      equ 0x0010   ; string prefix r
TF_STR_BYTES    equ 0x0020   ; string prefix b
TF_STR_FMT      equ 0x0040   ; string prefix f
TF_NUM_FLOAT    equ 0x0080   ; NUMBER has a fractional part or exponent
TF_NUM_IMAG     equ 0x0100   ; NUMBER has a j suffix

struc Token
    .kind:   resw 1  ; +0
    .flags:  resw 1  ; +2
    .lineno: resd 1  ; +4   1-based
    .start:  resq 1  ; +8   pointer into the source buffer
    .len:    resd 1  ; +16  bytes
    .col:    resd 1  ; +20  0-based column within the line
    .val:    resq 1  ; +24  reserved: materialized literal, or 0
endstruc                 ;  32 -> index by shl 5
TOKEN_SHIFT equ 5

;; TOK_POS tokptr -- that token's position in rcx, packed the way ast_make
;; takes it: the line in the low half and the column in the high half.  One
;; word, because a seventh argument to ast_make would be a stack argument at
;; fifty-odd call sites, and rcx because that is where every one of them
;; already puts the line.  Clobbers r11.
%macro TOK_POS 1                ; %1 = a Token*
    ; The column is read FIRST, so that %1 may itself be rcx -- writing ecx
    ; destroys the pointer.  %1 must not be r11.
    mov r11d, [%1 + Token.col]
    shl r11, 32
    mov ecx, [%1 + Token.lineno]
    or  rcx, r11
%endmacro

;; ============================================================================
;; SUITE_FOR text, line -- what an indented block is expected AFTER
;;
;; CPython says "expected an indented block after 'if' statement on line 3",
;; and the statement is the one thing par_suite cannot see: it is called from
;; fourteen places and takes only a Comp*.  Two words in parse_stmt.asm carry
;; it, which is safe because par_suite reads them before it can descend into a
;; nested suite that would overwrite them.  The macros live here rather than
;; in parse_stmt.asm because parse_try.asm writes them too.
;; ============================================================================
%macro SUITE_FOR 2              ; %1 = the text, %2 = a source of the line
    CSTRING rax, %1
    mov [rel psu_what], rax
    mov eax, %2
    mov [rel psu_line], eax
%endmacro

;; SUITE_FOR_HERE text -- the same, for a clause that is its own statement.
;; `else`, `except` and `finally` are blamed on THEIR line, not on the line
;; the `if` or the `try` opened on, so the line comes from the token the
;; parser is looking at.  Clobbers rax and rdi; rbx must be the Comp*.
%macro SUITE_FOR_HERE 1
    mov rdi, rbx
    call par_peek
    mov eax, [rax + Token.lineno]
    mov [rel psu_line], eax
    CSTRING rax, %1
    mov [rel psu_what], rax
%endmacro

;; ===========================================================================
;; Character classes.  One 256-byte table drives every scanning decision in
;; the lexer.
;; ===========================================================================
CC_DIGIT   equ 0x04
CC_IDSTART equ 0x08   ; A-Za-z_ and 0x80..0xFF (permissive UTF-8 lead byte)
CC_IDCONT  equ 0x10   ; IDSTART or DIGIT
CC_QUOTE   equ 0x20   ; ' "
CC_OPSTART equ 0x40   ; first byte of some operator or delimiter
CC_HEX     equ 0x80

;; ===========================================================================
;; AST.  Fixed 32-byte nodes in a bump arena, addressed by u32 index.  Node 0
;; is the reserved null node, so 0 doubles as "absent".
;;
;; Variable-arity children live in a separate u32 child-list arena: .clist is
;; the offset, .nchild the count.  They are built through a LIFO pending stack
;; (ast_mark / ast_push / ast_commit), because nested constructs are under
;; construction simultaneously -- f(a, [b, c], d) has three lists open at once.
;;
;; Anything that needs a PyObject (a constant, an identifier) stores a u32
;; index into comp.objs, a Buf of owned references.  That keeps nodes 32 bytes
;; and gives the error path a single place to release every object the parse
;; produced.
;; ===========================================================================

AST_NULL        equ 0
; --- expressions ---
AST_CONST       equ 1    ; a=obj index
AST_NAME        equ 2    ; a=obj index (identifier), subkind=ctx
AST_BINOP       equ 3    ; a=left b=right subkind=NB_*
AST_UNARYOP     equ 4    ; a=operand subkind=UOP_*
AST_BOOLOP      equ 5    ; clist=operands subkind=0 and / 1 or
AST_COMPARE     equ 6    ; a=left, clist=(op, node) pairs, nchild=pair count
AST_IFEXP       equ 7    ; a=test b=body c=orelse
AST_LAMBDA      equ 8    ; a=args b=body
AST_TUPLE       equ 9    ; clist, subkind=ctx
AST_LIST        equ 10   ; clist, subkind=ctx
AST_SET         equ 11   ; clist
AST_DICT        equ 12   ; clist=(key, value) pairs
AST_CALL        equ 13   ; a=func, clist=args, b=keyword list node
AST_ATTRIBUTE   equ 14   ; a=value b=obj index (name) subkind=ctx
AST_SUBSCRIPT   equ 15   ; a=value b=index subkind=ctx
AST_SLICE       equ 16   ; a=lower b=upper c=step
AST_STARRED     equ 17   ; a=value
AST_DOUBLESTARRED equ 18 ; a=value (only inside a call or dict display)
AST_KEYWORD     equ 19   ; a=obj index (name, 0 for **) b=value
AST_NAMEDEXPR   equ 20   ; a=target b=value  (walrus)
AST_YIELD       equ 21   ; a=value or 0
AST_YIELDFROM   equ 22   ; a=value
AST_AWAIT       equ 23   ; a=value
AST_JOINEDSTR   equ 24   ; clist=pieces
AST_FORMATTEDVALUE equ 25; a=value b=spec subkind=conversion
AST_LISTCOMP    equ 26   ; a=element, clist=comprehension clauses
AST_SETCOMP     equ 27
AST_DICTCOMP    equ 28   ; a=key b=value, clist=clauses
AST_GENEXP      equ 29
AST_COMPREHENSION equ 30 ; a=target b=iter, clist=conditions, subkind=is_async

; --- statements ---
AST_MODULE      equ 40   ; clist=body
AST_EXPRESSION  equ 41   ; a=expr        (the "eval" mode root)
AST_EXPR_STMT   equ 42   ; a=expr
AST_ASSIGN      equ 43   ; clist=targets b=value
AST_AUGASSIGN   equ 44   ; a=target b=value subkind=NB_*
AST_ANNASSIGN   equ 45   ; a=target b=annotation c=value
AST_IF          equ 46   ; a=test, clist=body, b=orelse block node
AST_WHILE       equ 47   ; a=test, clist=body, b=orelse
AST_FOR         equ 48   ; a=target b=iter c=body, clist=orelse block index
                         ; (nchild stays 0), subkind=is_async
AST_BLOCK       equ 49   ; clist=statements  (an else/elif tail)
AST_PASS        equ 50
AST_BREAK       equ 51
AST_CONTINUE    equ 52
AST_RETURN      equ 53   ; a=value or 0
AST_DELETE      equ 54   ; clist=targets
AST_RAISE       equ 55   ; a=exc b=cause
AST_ASSERT      equ 56   ; a=test b=msg
AST_GLOBAL      equ 57   ; clist=obj indices
AST_NONLOCAL    equ 58   ; clist=obj indices
AST_IMPORT      equ 59   ; clist=alias nodes
AST_IMPORTFROM  equ 60   ; a=obj index (module), clist=aliases, subkind=level
AST_ALIAS       equ 61   ; a=obj index (name) b=obj index (asname or 0)
                         ; c=obj index of the name actually bound: the asname,
                         ; or the mangled leading component of the dotted name
AST_FUNCTIONDEF equ 62   ; a=obj index (name) b=args, clist=body, c=return ann
AST_CLASSDEF    equ 63   ; a=obj index (name) b=bases call, clist=body, c=extra
AST_TRY         equ 64   ; clist=body, a=handlers block, b=orelse, c=finalbody
AST_HANDLER     equ 65   ; a=type b=obj index (name), clist=body
AST_WITH        equ 66   ; clist=items, a=body block, subkind=is_async
AST_WITHITEM    equ 67   ; a=context b=optional vars
AST_ARGUMENTS   equ 68   ; clist=arg nodes, a=extra node
AST_ARG         equ 69   ; a=obj index (name) b=annotation c=default
AST_MATCH       equ 70   ; a=subject, clist=cases
AST_EXTRA       equ 71   ; raw payload continuation for nodes needing >5 slots
AST_DECORATED   equ 72   ; clist=decorators, a=the def or class they wrap

; --- match ---
; A pattern is not an expression: `case x` binds x rather than reading it, and
; `case C(a)` calls nothing.  They get their own node kinds for that reason --
; sharing AST_NAME and AST_CALL would make every consumer ask which it was.
AST_CASE        equ 73   ; a=pattern b=guard, clist=body
AST_PAT_VALUE   equ 74   ; a=expr; subkind 1 = compare by identity (None/True/False)
AST_PAT_CAPTURE equ 75   ; a=obj index (name), 0 for the `_` wildcard
AST_PAT_SEQUENCE equ 76  ; clist=sub-patterns, b=1+index of the starred one, 0 if none
AST_PAT_MAPPING equ 77   ; clist=key expr / value pattern pairs, b=obj index of **rest
AST_PAT_CLASS   equ 78   ; a=class expr, clist=positional then keyword patterns,
                         ; b=how many are positional
AST_PAT_KEYWORD equ 79   ; a=obj index (name) b=pattern
AST_PAT_OR      equ 80   ; clist=alternatives
AST_PAT_AS      equ 81   ; a=pattern (0 = wildcard) b=obj index (name)

AST_INTERACTIVE equ 82   ; clist=body    (the "single" mode root); produced
                         ; only by compile_ast_raw, never compiled

; PEP 695.  The parameters are parsed into these and then ignored by
; everything downstream: a type parameter is visible only to annotations, and
; annotations are not evaluated here.  They exist so that the AST says what
; the source said -- the old bug list carried what the RUNTIME would additionally need.
AST_TYPEALIAS   equ 83   ; a=target name node, b=value; type params on the side
AST_TYPEPARAMS  equ 84   ; clist=the parameters; hung off a def, class or alias
                         ; through Comp.typeparams rather than a field, because
                         ; a def has none free
AST_TYPEVAR     equ 85   ; a=obj index (name), b=bound or 0
AST_PARAMSPEC   equ 86   ; a=obj index (name)
AST_TYPEVARTUPLE equ 87  ; a=obj index (name)

; The "func_type" start symbol: `(int, str) -> bool`, the type comment form a
; stub file carries.  Produced only by compile_ast_raw, never compiled.
AST_FUNCTIONTYPE equ 88  ; clist=argument types, a=the return type

AST_COUNT       equ 88

; AstNode.subkind for expression context
CTX_LOAD  equ 0
CTX_STORE equ 1
CTX_DEL   equ 2

; AstNode.subkind for AST_UNARYOP
UOP_POS    equ 0   ; +x
UOP_NEG    equ 1   ; -x
UOP_INVERT equ 2   ; ~x
UOP_NOT    equ 3   ; not x

; AstNode.subkind for AST_BOOLOP
BOOL_AND equ 0
BOOL_OR  equ 1

; Comparison operators, as stored in an AST_COMPARE child list.  The first six
; match CPython's COMPARE_OP codes so codegen can shift them straight into the
; oparg; the last four are separate opcodes (IS_OP and CONTAINS_OP) rather than
; comparisons, which is why the enum has to be wider than CMP_*.
CMPOP_LT    equ 0
CMPOP_LE    equ 1
CMPOP_EQ    equ 2
CMPOP_NE    equ 3
CMPOP_GT    equ 4
CMPOP_GE    equ 5
CMPOP_IN    equ 6
CMPOP_NOTIN equ 7
CMPOP_IS    equ 8
CMPOP_ISNOT equ 9

struc AstNode
    .kind:    resb 1  ; +0   AST_*
    .subkind: resb 1  ; +1   operator / context / async flag
    .flags:   resw 1  ; +2
    .lineno:  resd 1  ; +4
    .a:       resd 1  ; +8
    .b:       resd 1  ; +12
    .c:       resd 1  ; +16
    .clist:   resd 1  ; +20  offset into the child-list arena
    .nchild:  resd 1  ; +24
    .col:     resd 1  ; +28
endstruc                  ; 32 -> index by shl 5
AST_SHIFT equ 5

;; Where a node ENDS.  Not in the node: it is exactly 32 bytes and addressed
;; by `shl 5`, and two more fields would cost the doubling to 64 for two
;; words.  A parallel Buf indexed by the same u32 costs eight bytes a node and
;; leaves every existing shift alone; ast_make is the only thing that makes a
;; node, so the two cannot drift apart.
struc AstSpan
    .end_lineno: resd 1  ; +0   -1 when it was not recorded
    .end_col:    resd 1  ; +4
endstruc                 ; 8

;; ===========================================================================
;; Buf - the growable array this codebase otherwise lacks.  Used for the token
;; array, the child-list arena, the instruction stream, and all three byte
;; emitters.  ap_malloc/ap_realloc are fatal on OOM, so no call here can fail.
;; ===========================================================================
struc Buf
    .data:  resq 1  ; +0
    .len:   resq 1  ; +8   elements in use
    .cap:   resq 1  ; +16  elements allocated
    .elsz:  resq 1  ; +24  element size in bytes
endstruc                ; 32
BUF_MIN_CAP equ 64

;; ===========================================================================
;; Arena - bump allocation, released wholesale.  A compilation is a bounded
;; episode, so the AST and the symbol table never need individual frees.  The
;; exception is anything holding a PyObject: those live in comp.objs and are
;; refcounted.
;; ===========================================================================
struc Arena
    .cur:    resq 1  ; +0   next free byte
    .end:    resq 1  ; +8   end of the current chunk
    .chunks: resq 1  ; +16  chunk list head: [next][size][payload...]
    .total:  resq 1  ; +24  high-water mark, for --selftest-compile
endstruc                 ; 32
ARENA_CHUNK equ 65536

;; ===========================================================================
;; Instr - one emitted instruction, before assembly.  Never a CACHE and never
;; an EXTENDED_ARG: both are synthesized by the writer from the opcode metadata
;; table and the resolved oparg, so no emitter can forget them.
;; ===========================================================================
struc Instr
    .opcode:  resb 1  ; +0
    .flags:   resb 1  ; +1   IF_*
    .handler: resw 1  ; +2   Handler index + 1; 0 = not inside a try
    .oparg:   resd 1  ; +4   literal oparg, or a label id when IF_LABELARG
    .line:    resd 1  ; +8   source line; 0 = no location
    .offset:  resd 1  ; +12  code-unit offset, filled by the sizing fixpoint
    ; The rest of the location, so that the line table can carry columns and a
    ; traceback rendered from OUR bytecode gets its caret row.  .col is -1 when
    ; the instruction has only a line, which is what every emitter that
    ; attributes an instruction to some other line than the node's produces.
    .end_line: resd 1 ; +16
    .col:      resd 1 ; +20  a BYTE offset into the line, zero-based
    .end_col:  resd 1 ; +24
    .pad:      resd 1 ; +28
endstruc                  ; 32 -> index by shl 5
INSTR_SHIFT equ 5

IF_LABELARG  equ 0x01   ; .oparg names a label, resolve it to a delta
IF_JREL_FWD  equ 0x02   ; delta = target - (offset + size)
IF_JREL_BACK equ 0x04   ; delta = (offset + size) - target
IF_NOFALL    equ 0x08   ; control does not reach the next instruction
IF_NOLINE    equ 0x10   ; emit "no location" in the line table
IF_LINE0     equ 0x20   ; the location is line ZERO, which is not the same as
                        ; no location: CPython gives a module's leading RESUME
                        ; line 0, and `co_lines()` says so.  Instr.line cannot
                        ; carry it, because 0 there means "unset"

;; ===========================================================================
;; Opcode metadata.  One table drives four things: CACHE padding, instruction
;; sizing, stack-depth accounting, and successor computation.  Routing every
;; emission through it is what makes "I forgot the caches on LOAD_SUPER_ATTR"
;; structurally impossible rather than a per-call-site discipline.
;; ===========================================================================
struc OpMeta
    .cache:  resb 1  ; +0  trailing CACHE words
    .effect: resb 1  ; +1  signed net stack effect, or SE_VAR
    .flags:  resb 1  ; +2  OM_*
    .jeff:   resb 1  ; +3  signed net effect along the taken jump edge
endstruc                 ; 4 -> index by shl 2

SE_VAR       equ 0x80   ; effect depends on the oparg: call comp_effect_var
OM_HASARG    equ 0x01
OM_JUMP      equ 0x02   ; has a jump edge (oparg names a target)
OM_JUMPBACK  equ 0x04   ; the jump edge runs backward
OM_NOFALL    equ 0x08   ; control does not fall through

;; ===========================================================================
;; Compiler error codes.  Every compiler function returns 0/NULL on failure
;; with comp.err_set non-zero; nothing here raises.
;; ===========================================================================
; A warning the compiler wants emitted once there is an interpreter to emit
; it from.  CPython's tokenizer warns where this one may not: it runs before
; any Python frame exists, which is the same reason it may not raise.  They
; are recorded here and handed to warnings.warn_explicit at the end, which
; takes a filename and a line rather than reading them off a frame.
COMP_WARN_TEXT equ 96
struc CompWarn
    .msg:    resb COMP_WARN_TEXT  ; the message, COPIED: some are composed
    .lineno: resd 1
    .pad:    resd 1
endstruc
COMP_MAX_WARNS equ 16

struc CompErr
    .type:   resq 1  ; +0  exception type object
    .msg:    resq 1  ; +8  const char*
    .lineno: resd 1  ; +16
    .col:    resd 1  ; +20
    .set:    resd 1  ; +24  non-zero once an error is recorded
    .end_lineno: resd 1  ; +28  the end of the span the error covers, which
    .end_col:    resd 1  ; +32  comp_error defaults to the one character at
    .pad:        resd 1  ; +36  (lineno, col) -- CPython narrows some errors
endstruc                 ;      to a whole token or a whole subexpression

; Compilation modes, matching CPython's start symbols.  SINGLE compiles
; exactly as EXEC -- there is no PRINT_EXPR here, so the interactive echo is
; not reproducible -- and differs only in the root node the AST gets, which is
; the one thing about it that IS observable.
CMODE_EXEC   equ 0
CMODE_EVAL   equ 1
CMODE_SINGLE equ 2
CMODE_FUNC_TYPE equ 3

; The parser's own recursion guard.  apython's recursion_depth counts Python
; frames only, so deeply nested parentheses would otherwise blow the machine
; stack before anything noticed.
COMP_MAX_DEPTH equ 200

;; ===========================================================================
;; Pratt binding powers.  Higher binds tighter; a handler that recurses at its
;; own power is left-associative, one below is right-associative.
;; ===========================================================================
BP_NONE     equ 0
BP_LAMBDA   equ 2
BP_WALRUS   equ 3
BP_TERNARY  equ 4
BP_OR       equ 6
BP_AND      equ 8
BP_NOT      equ 10
BP_COMPARE  equ 12
; A starred element's operand: an or_expr, so `|` is absorbed and `in` is not.
; It sits between the two rather than on either, because the driver continues
; only while lbp > min_bp.
BP_STAROP   equ 13
BP_BITOR    equ 14
BP_BITXOR   equ 16
BP_BITAND   equ 18
BP_SHIFT    equ 20
BP_ARITH    equ 22
BP_TERM     equ 24
BP_UNARY    equ 26
BP_POWER    equ 28
BP_AWAIT    equ 30
BP_POSTFIX  equ 32

;; ===========================================================================
;; Lexer state.  One pass over the source fills comp.tokens; the parser then
;; walks a plain array with a u32 cursor, so backtracking -- which Python needs
;; for `with (a as x, b as y)`, `def f[T](...)`, and starred-target validation
;; -- is an index reset rather than a snapshot of all of this.
;; ===========================================================================
LEX_MAX_INDENT equ 100
LEX_TABSIZE    equ 8

; How deeply brackets may nest before the lexer stops recording where each
; was opened.  Past this the depth still counts; only the position is lost.
LEX_MAX_BRACKET equ 200

; PRule.flags
PR_CHAIN    equ 0x01     ; a comparison operator: folds into one n-ary node

struc PRule
    .prefix: resq 1      ; fn(Comp*) -> node index, or 0 if not a prefix
    .infix:  resq 1      ; fn(Comp*, node left) -> node index, or 0
    .lbp:    resb 1      ; left binding power; 0 means "not an infix operator"
    .rbp:    resb 1      ; the power its handler recurses at
    .aux:    resb 1      ; NB_* / CMP_* / UOP_* payload
    .flags:  resb 1      ; PR_*
    .pad:    resd 1
endstruc

struc Lexer
    .cur:          resq 1   ; +0   read cursor into comp.src
    .end:          resq 1   ; +8   one past the last source byte
    .line_start:   resq 1   ; +16  first byte of the current line, for columns
    .lineno:       resd 1   ; +24  1-based
    .paren_depth:  resd 1   ; +28  suppresses NEWLINE and INDENT while > 0
    .indent_top:   resd 1   ; +32  index of the live entry in .indents
    .atbol:        resd 1   ; +36  at the beginning of a logical line
    ; The open brackets, innermost last: the character, the line and the
    ; column of each.  CPython's tokenizer names the one that was never
    ; closed and points at where it was opened, and nothing else in the token
    ; stream can say where that was.
    .open_ch:      resb LEX_MAX_BRACKET      ; the '(', '[' or '{'
    .open_line:    resd LEX_MAX_BRACKET
    .open_col:     resd LEX_MAX_BRACKET
    .indents:      resd LEX_MAX_INDENT  ; column stack, .indents[0] == 0
endstruc

;; ===========================================================================
;; Comp - the whole state of one compilation.
;;
;; Everything indexed is a Buf, never an Arena: nodes and child lists are
;; addressed by u32 index and the backing store is reallocated as it grows, so
;; an index stays valid where a pointer would not.
;;
;; .objs is the one place refcounts live.  Every PyObject the front end
;; produces -- interned identifiers, literal constants -- is appended there and
;; referenced from an AstNode by index, which keeps nodes at 32 bytes and gives
;; the error path a single loop that releases everything the parse allocated.
;; ===========================================================================
struc Comp
    .src:       resq 1              ; +0   owned, NUL-padded normalized source
    .srclen:    resq 1              ; +8
    .filename:  resq 1              ; +16  PyStrObject*, owned
    .mode:      resd 1              ; +24  CMODE_*
    .depth:     resd 1              ; +28  parser recursion depth
    .tok_idx:   resd 1              ; +32  parser cursor into .tokens
    .root:      resd 1              ; +36  AST index of the parse root
    .tokens:    resb Buf_size       ; +40  Token[]
    .nodes:     resb Buf_size       ; AstNode[]; index 0 is the null node
    .spans:     resb Buf_size       ; AstSpan[], parallel to .nodes
    .children:  resb Buf_size       ; u32[] committed child lists
    .pending:   resb Buf_size       ; u32[] LIFO scratch for lists under construction
    .objs:      resb Buf_size       ; PyObject*[], owned
    .typeparams: resb Buf_size      ; u32[], parallel to .nodes: the
                                    ; AST_TYPEPARAMS node a def, class or type
                                    ; alias carries, or 0.  A side table
                                    ; because AstNode is full: PEP 695 arrived
                                    ; after every field had a use
    .typeignores: resb Buf_size     ; u32[] pairs (lineno, obj index of the
                                    ; tag) for every `# type: ignore`, which
                                    ; belongs to the Module rather than to any
                                    ; statement
    .typecomments: resb Buf_size    ; u32[], parallel to .nodes: the obj index
                                    ; of a `# type:` comment's text, or 0.
                                    ; Another side table for the same reason
                                    ; typeparams is one, and collected only
                                    ; when PyCF_TYPE_COMMENTS asked for them
    .rawnames:  resb Buf_size       ; u32[], parallel to .objs: for an
                                    ; identifier that private-name mangling
                                    ; rewrote, the obj index of the name as it
                                    ; was WRITTEN.  0 for everything else.
                                    ; The compiler uses the mangled name; the
                                    ; AST reports this one, as CPython's does
    .scopes:    resb Buf_size       ; Scope[]; index 0 reserved
    .cur_unit:  resq 1              ; the CompUnit being emitted into
    .cur_scope: resd 1
    .pad1:      resd 1
    .private:   resq 1              ; the enclosing class's name, for private
                                    ; name mangling; 0 outside a class body
    .want_tc:   resd 1              ; PyCF_TYPE_COMMENTS: collect `# type:`
    .pending_tc: resd 1             ; a `# type:` comment par_suite found after
                                    ; the colon, waiting for the statement that
                                    ; will own it -- `for x in y:  # type: int`
                                    ; is the For's, and the For node does not
                                    ; exist until its body has been parsed
    ; PEP 572's two rules about a walrus in a comprehension, which are about
    ; WHERE in the comprehension it is written rather than about any scope.
    ; The symbol table sets each around the one visit it covers.
    .in_comp_iter: resd 1           ; visiting a `for` TARGET: the names bound
                                    ; here are iteration variables
    .in_comp_iterable: resd 1       ; visiting a clause's ITERABLE, where no
                                    ; walrus may appear at all
    ; A future statement is legal only at the top of the file: after the
    ; docstring, and after any other future statements.  par_module closes
    ; the window as soon as it parses anything else, and ps_note_future
    ; refuses one that arrives late.  It matters more than it reads: the
    ; whole file is parsed before anything is emitted, so a future import
    ; three hundred lines down would otherwise change how the annotations
    ; above it were compiled.
    .future_shut: resd 1            ; no more future statements are allowed
    .future_here: resd 1            ; the statement just parsed was one
    .future_nstmt: resd 1           ; whether any statement has been seen, so
                                    ; that a docstring is only ever the first
    .future_anno: resd 1            ; PEP 563: `from __future__ import
                                    ; annotations` was seen, so every
                                    ; annotation is stored as its SOURCE TEXT
                                    ; rather than evaluated.  A Comp field
                                    ; rather than a CompUnit one because it is
                                    ; a property of the FILE: a nested def
                                    ; inherits it, and there is nowhere to
                                    ; inherit it from once the enclosing unit
                                    ; is finished
    ; Four of these and a pad, so the fields below keep their alignment: the
    ; struct is a run of resd and an odd count shifts everything after it.
    .future_barry: resd 1          ; CO_FUTURE_BARRY_AS_BDFL or zero
    .future_pad4: resd 1
    .err:       resb CompErr_size
    .warn_n:    resd 1              ; how many of .warns are filled
    .warn_pad:  resd 1
    .warns:     resb CompWarn_size * COMP_MAX_WARNS
    .lex:       resb Lexer_size
endstruc

;; ===========================================================================
;; CompUnit - the code object under construction for one scope.
;;
;; Instructions are a flat array with symbolic labels, not a control-flow
;; graph.  Fidelity here is semantic rather than byte-for-byte, so CPython's
;; peephole and dead-code passes have nothing to do, and stack depth works as
;; a worklist over the flat array treating labels as join points.  That single
;; decision is the largest saving against CPython's flowgraph.c.
;;
;; .consts and .names hold BORROWED references: every literal already lives in
;; comp.objs, which owns it.  The tuples built at assembly time take their own.
;; ===========================================================================
;; A protected region under construction.  Handlers form a tree through
;; .parent; every instruction is stamped with the innermost one that covers it,
;; and the ranges are recovered afterwards by run-length encoding that stamp.
;; Computing ranges that way rather than from a stack of open regions is what
;; makes them come out disjoint and sorted by construction -- which matters,
;; because exc_table_find_handler scans linearly and takes the FIRST match, so
;; overlapping entries would silently pick the wrong handler.
struc Handler
    .target:  resd 1          ; label the handler starts at
    .lasti:   resd 1          ; 0 or 1: does the unwinder push the offset?
    .depth:   resd 1          ; value-stack depth to truncate to; -1 until the
                              ; depth pass runs
    .parent:  resd 1          ; enclosing handler index, -1 = none
    .open:    resd 1          ; instruction index where the region was opened
    .bias:    resd 1          ; items live at `open` that the handler unwinds
                              ; away: a `with` opens its region with the
                              ; enter-result still on the stack, so the depth
                              ; read there is one above what the handler wants
endstruc                      ; 24

;; A loop being generated: where `break` and `continue` go, and how much the
;; value stack has to be unwound to get there.  A for loop leaves its iterator
;; on the stack across the body, so `break` must drop it; `continue` jumps back
;; to the FOR_ITER, which still wants it.
struc LoopFrame
    .brk:    resd 1          ; label for `break`
    .cont:   resd 1          ; label for `continue`
    .npop:   resd 1          ; stack items `break` must pop first
    .fdepth: resd 1          ; height of the finally stack at loop entry, so
                             ; break and continue unwind only what they leave
endstruc                     ; 16

struc CompUnit
    .instrs:    resb Buf_size   ; Instr[]
    .loops:     resb Buf_size   ; LoopFrame[], innermost last
    .handlers:  resb Buf_size   ; Handler[]
    .finallys:  resb Buf_size   ; per enclosing block: (handler << 32) | node
    .cur_handler: resd 1        ; index into .handlers, -1 = unprotected
    .pad4:      resd 1
    .labels:    resb Buf_size   ; int32[]: label id -> instruction index, -1 unbound
    .consts:    resb Buf_size   ; Value[]   (borrowed)
    .names:     resb Buf_size   ; PyStrObject*[] (borrowed)
    .prefix:    resb Buf_size   ; uint8[]: EXTENDED_ARG words per instruction
    .flags:     resd 1
    .argcount:  resd 1
    .posonly:   resd 1
    .kwonly:    resd 1
    .nlocals:   resd 1
    .stacksize: resd 1
    .firstline: resd 1
    ; The location the emitters are currently generating for.  cg_expr and
    ; cg_stmt set all four from the node before dispatching and restore them
    ; after, so an emitter that says nothing about where it is inherits its
    ; statement's position rather than the last one anybody happened to write.
    .curline:   resd 1
    .curend:    resd 1
    .curcol:    resd 1
    .curendcol: resd 1
    ; The line of the last instruction actually EMITTED, which is not
    ; .curline: cg_stmt restores that to the enclosing statement's before the
    ; implicit `return None` and a loop's back edge are emitted, so both got
    ; the wrong location.  Written by cg_emit and read by whoever needs "where
    ; did the code actually get to".
    .lastline:  resd 1
    .lastend:   resd 1
    .lastcol:   resd 1
    .lastendcol: resd 1
    .name:      resq 1          ; PyStrObject*, borrowed
    .qualname:  resq 1
    .filename:  resq 1
    .comp:      resq 1          ; the owning Comp, for scope lookups
    .scope:     resd 1          ; this unit's Scope index
    .pad3:      resd 1
endstruc

; co_stacksize is emitted with this much slack.  frame_free recomputes a
; frame's size from co_nlocalsplus + co_stacksize and hands it back to the
; frame pool, so an over-estimate costs a few bytes per frame while an
; under-estimate corrupts the pool's free list and crashes somewhere unrelated.
; The margin makes a single-slot modelling error in a rarely-exercised opcode
; harmless rather than fatal; it comes out once the depth pass is trusted.
COMP_STACK_SLACK equ 4

;; ===========================================================================
;; Symbol table.
;;
;; One Scope per binding block.  Two passes: the first records what each block
;; binds and uses, the second classifies every name as local, cell, free,
;; explicit global or implicit global.  The classification is what decides
;; which opcode a name compiles to, and the rule that matters most is a
;; negative one: module and class blocks are NOT function-like, so nothing in
;; them is ever a fast local.  Every name there goes through LOAD_NAME against
;; the frame's locals mapping -- which is exactly the dict exec(src, d) passes,
;; and the reason that call can hand results back.
;;
;; Scopes live in a Buf and are addressed by index; index 0 is reserved so that
;; a 0 parent means "no enclosing scope".
;; ===========================================================================

SCOPE_MODULE   equ 0
SCOPE_CLASS    equ 1
SCOPE_FUNCTION equ 2
SCOPE_LAMBDA   equ 3
SCOPE_COMP     equ 4

; What a block does with a name.  Mirrors CPython's symtable flags closely
; enough that its analyze_name rules can be followed step for step.
DEF_GLOBAL   equ 0x001
DEF_LOCAL    equ 0x002
DEF_PARAM    equ 0x004
DEF_NONLOCAL equ 0x008
DEF_IMPORT   equ 0x010
DEF_USE      equ 0x020
; The name is unbound somewhere in this block -- an explicit `del`, or the
; implicit one at the end of an `except E as e` clause.  A local that can be
; unbound has to be read with LOAD_FAST_CHECK, or reading it after the delete
; returns whatever was in the slot instead of raising.
DEF_UNBOUND  equ 0x040
; The name is bound -- or declared global -- in a CLASS body and is free in a
; block nested inside it.  The class body keeps its own resolved scope: `x = 1`
; there is still STORE_NAME into the class dict, and `global x; x = 1` is still
; STORE_GLOBAL.  But the name must ALSO appear among the block's free
; variables, because the MAKE_FUNCTION for the nested block is built inside the
; class body and its closure tuple is LOAD_CLOSURE'd from a slot there.
; CPython spells this DEF_FREE_CLASS: update_symbols sets it, and compile.c's
; dictbytype(symbols, FREE, DEF_FREE_CLASS, ncells) is what lands the name in
; co_freevars without disturbing its scope.
DEF_FREE_CLASS equ 0x080
; A comprehension's iteration variable, in the comprehension's own scope.
; PEP 572 forbids a walrus from rebinding one, and the check needs to know
; which of the scope's locals came from a `for` target rather than from an
; ordinary assignment inside the body.
DEF_COMP_ITER  equ 0x100

; The resolved answer, stored in bits 12..14.
SCOPE_SHIFT      equ 12
SCOPE_MASK       equ 0x7000
SYM_LOCAL           equ 1
SYM_GLOBAL_EXPLICIT equ 2
SYM_GLOBAL_IMPLICIT equ 3
SYM_FREE            equ 4
SYM_CELL            equ 5

; Scope.flags
SCF_GENERATOR equ 0x01
SCF_COROUTINE equ 0x02
; SCF_COROUTINE says "this block is a coroutine", and a bare `await` sets it
; just as `async def` does -- so it cannot answer "was this block DECLARED
; async", which is what refusing an `await` in a plain def needs.  This bit
; is set only by sym_enter_function, and only for an `async def`.
SCF_ASYNC_DEF equ 0x08
; PEP 695: this block is a type-parameter wrapper sitting directly inside a
; CLASS body, so a name that would otherwise be an implicit global is looked
; for in that body's namespace first.  Ordinary scoping cannot do it -- a
; class body is invisible to a nested function -- so the wrapper carries a
; __classdict__ free variable holding the mapping and reads through it with
; LOAD_FROM_DICT_OR_GLOBALS.  CPython calls the same bit ste_can_see_class_scope.
SCF_SEES_CLASS equ 0x04

struc Scope
    .parent:    resd 1          ; scope index, 0 = none
    .kind:      resd 1          ; SCOPE_*
    .flags:     resd 1          ; SCF_*
    .node:      resd 1          ; the AST node this block belongs to
    .symbols:   resq 1          ; PyDictObject*: name -> SmallInt(flags)
    .name:      resq 1          ; PyStrObject*, borrowed from comp.objs
    .argcount:  resd 1
    .posonly:   resd 1
    .kwonly:    resd 1
    .co_flags:  resd 1
    .varnames:  resb Buf_size   ; u64 name Values, parameters first
    .cellvars:  resb Buf_size
    .freevars:  resb Buf_size
    .localsplus: resb Buf_size  ; varnames ++ new cellvars ++ freevars
    .children:  resb Buf_size   ; u32 scope indices, in source order
    .nlocals:   resd 1          ; == len(varnames)
    .ncells:    resd 1
    .nfrees:    resd 1
    .pad2:      resd 1
endstruc


;; ============================================================================
;; The f-string scanner's state, in src/compiler/fstrscan.asm.
;;
;; One of these is threaded through the whole recursion, because a nested
;; literal or a nested field can cross a newline and the lexer's line counter
;; has to move with it -- on the failure paths as much as on the successful
;; ones, since the message names the line the scan gave up on.
;; ============================================================================
struc FsSkip
    .nl:        resq 1  ; +0:  newlines crossed so far, not yet applied
    .lstart:    resq 1  ; +8:  where the last of those lines starts
    .level:     resq 1  ; +16: f-strings currently open, capped at 150
    .err:       resq 1  ; +24: FSE_*, or FSE_OK
    .badp:      resq 1  ; +32: where the error is
endstruc

;; Two callers keep one of these in a frame slot whose offset is written down
;; rather than derived -- lex_run's LR_SKIP and par_fstring_field's FF_SKIP --
;; because the slot above each was chosen to leave exactly this much room.  A
;; struct that grows silently lands on that slot, and the symptom is one field
;; reading as garbage.
%if FsSkip_size != 40
  %error "FsSkip changed size: check LR_SKIP in lex.asm and FF_SKIP in fstring.asm"
%endif

FSE_OK            equ 0
FSE_UNTERM        equ 1   ; a literal ran off the end
FSE_EXPECT_RBRACE equ 2   ; a replacement field ran off the end
FSE_UNMATCHED     equ 3   ; a closing bracket with nothing open
FSE_TOO_NESTED    equ 4   ; more than FS_MAXFSTRING f-strings deep

;; What fs_skip_literal needs to know about the literal it is starting on.
;; They are the TF_STR_* bits under another name, so a caller that already has
;; those can pass them straight through.
FS_LIT_RAW equ TF_STR_RAW
FS_LIT_FMT equ TF_STR_FMT

;; PEP 701 removed the limit on how deeply an EXPRESSION may nest inside a
;; field; this one it kept.  Measured against CPython 3.12: 149 levels parse
;; and the 150th is `too many nested f-strings`.
FS_MAXFSTRING equ 150

%endif ; COMPILER_INC
