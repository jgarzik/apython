; opcodes.inc - Python 3.12 opcode definitions

%ifndef OPCODES_INC
%define OPCODES_INC

; Python 3.12 opcodes
OP_CACHE                     equ 0
OP_POP_TOP                   equ 1
OP_PUSH_NULL                 equ 2
OP_INTERPRETER_EXIT          equ 3
OP_END_FOR                   equ 4
OP_END_SEND                  equ 5
OP_NOP                       equ 9
OP_UNARY_NEGATIVE            equ 11
OP_UNARY_NOT                 equ 12
OP_UNARY_INVERT              equ 15
OP_RESERVED                  equ 17
OP_BINARY_SUBSCR             equ 25
OP_BINARY_SLICE              equ 26
OP_STORE_SLICE               equ 27
OP_GET_LEN                   equ 30
OP_MATCH_MAPPING             equ 31
OP_MATCH_SEQUENCE            equ 32
OP_MATCH_KEYS                equ 33
OP_PUSH_EXC_INFO             equ 35
OP_CHECK_EXC_MATCH           equ 36
OP_CHECK_EG_MATCH            equ 37
OP_WITH_EXCEPT_START         equ 49
OP_GET_AITER                 equ 50
OP_GET_ANEXT                 equ 51
OP_BEFORE_ASYNC_WITH         equ 52
OP_BEFORE_WITH               equ 53
OP_END_ASYNC_FOR             equ 54
OP_CLEANUP_THROW             equ 55
OP_STORE_SUBSCR              equ 60
OP_DELETE_SUBSCR              equ 61
OP_GET_ITER                  equ 68
OP_GET_YIELD_FROM_ITER       equ 69
OP_LOAD_BUILD_CLASS          equ 71
OP_LOAD_ASSERTION_ERROR      equ 74
OP_RETURN_GENERATOR          equ 75
OP_RETURN_VALUE              equ 83
OP_SETUP_ANNOTATIONS         equ 85
OP_LOAD_LOCALS               equ 87
OP_POP_EXCEPT                equ 89
OP_HAVE_ARGUMENT             equ 90
OP_STORE_NAME                equ 90
OP_DELETE_NAME               equ 91
OP_UNPACK_SEQUENCE           equ 92
OP_FOR_ITER                  equ 93
OP_UNPACK_EX                 equ 94
OP_STORE_ATTR                equ 95
OP_DELETE_ATTR               equ 96
OP_STORE_GLOBAL              equ 97
OP_DELETE_GLOBAL              equ 98
OP_SWAP                      equ 99
OP_LOAD_CONST                equ 100
OP_LOAD_NAME                 equ 101
OP_BUILD_TUPLE               equ 102
OP_BUILD_LIST                equ 103
OP_BUILD_SET                 equ 104
OP_BUILD_MAP                 equ 105
OP_LOAD_ATTR                 equ 106
OP_COMPARE_OP                equ 107
OP_IMPORT_NAME               equ 108
OP_IMPORT_FROM               equ 109
OP_JUMP_FORWARD              equ 110
OP_POP_JUMP_IF_FALSE         equ 114
OP_POP_JUMP_IF_TRUE          equ 115
OP_LOAD_GLOBAL               equ 116
OP_IS_OP                     equ 117
OP_CONTAINS_OP               equ 118
OP_RERAISE                   equ 119
OP_COPY                      equ 120
OP_RETURN_CONST              equ 121
OP_BINARY_OP                 equ 122
OP_SEND                      equ 123
OP_LOAD_FAST                 equ 124
OP_STORE_FAST                equ 125
OP_DELETE_FAST               equ 126
OP_LOAD_FAST_CHECK           equ 127
OP_POP_JUMP_IF_NOT_NONE      equ 128
OP_POP_JUMP_IF_NONE          equ 129
OP_RAISE_VARARGS             equ 130
OP_GET_AWAITABLE             equ 131
OP_MAKE_FUNCTION             equ 132
OP_BUILD_SLICE               equ 133
OP_JUMP_BACKWARD_NO_INTERRUPT equ 134
OP_MAKE_CELL                 equ 135
OP_LOAD_CLOSURE              equ 136
OP_LOAD_DEREF                equ 137
OP_STORE_DEREF               equ 138
OP_DELETE_DEREF              equ 139
OP_JUMP_BACKWARD             equ 140
OP_LOAD_SUPER_ATTR           equ 141
OP_CALL_FUNCTION_EX          equ 142
OP_LOAD_FAST_AND_CLEAR       equ 143
OP_EXTENDED_ARG              equ 144
OP_LIST_APPEND               equ 145
OP_SET_ADD                   equ 146
OP_MAP_ADD                   equ 147
OP_COPY_FREE_VARS            equ 149
OP_YIELD_VALUE               equ 150
OP_RESUME                    equ 151
OP_MATCH_CLASS               equ 152
OP_FORMAT_VALUE              equ 155
OP_BUILD_CONST_KEY_MAP       equ 156
OP_BUILD_STRING              equ 157
OP_LIST_EXTEND               equ 162
OP_SET_UPDATE                equ 163
OP_DICT_MERGE                equ 164
OP_DICT_UPDATE               equ 165
OP_CALL                      equ 171
OP_KW_NAMES                  equ 172
OP_CALL_INTRINSIC_1          equ 173
OP_CALL_INTRINSIC_2          equ 174
OP_LOAD_FROM_DICT_OR_GLOBALS equ 175
OP_LOAD_FROM_DICT_OR_DEREF   equ 176

; BINARY_OP argument constants
NB_ADD              equ 0
NB_AND              equ 1
NB_FLOOR_DIVIDE     equ 2
NB_LSHIFT           equ 3
NB_MATRIX_MULTIPLY  equ 4
NB_MULTIPLY         equ 5
NB_REMAINDER        equ 6
NB_OR               equ 7
NB_POWER            equ 8
NB_RSHIFT           equ 9
NB_SUBTRACT         equ 10
NB_TRUE_DIVIDE      equ 11
NB_XOR              equ 12
NB_INPLACE_ADD      equ 13
NB_INPLACE_AND      equ 14
NB_INPLACE_FLOOR_DIVIDE equ 15
NB_INPLACE_LSHIFT   equ 16
NB_INPLACE_MATRIX_MULTIPLY equ 17
NB_INPLACE_MULTIPLY equ 18
NB_INPLACE_REMAINDER equ 19
NB_INPLACE_OR       equ 20
NB_INPLACE_POWER    equ 21
NB_INPLACE_RSHIFT   equ 22
NB_INPLACE_SUBTRACT equ 23
NB_INPLACE_TRUE_DIVIDE equ 24
NB_INPLACE_XOR      equ 25

; Number of CACHE entries following each opcode
; (inline cache slots, each 2 bytes)

; COMPARE_OP argument encoding in Python 3.12
; The argument is (comparison_op << 4) | predicate_mask
; But for the basic comparison ops:
CMP_LT equ 0
CMP_LE equ 1
CMP_EQ equ 2
CMP_NE equ 3
CMP_GT equ 4
CMP_GE equ 5

; apython's own specialized opcodes.
;
; The interpreter rewrites a generic opcode into one of these on first
; execution, once it has seen what the site's operands actually are.  They
; occupy numbers CPython 3.12 leaves unused, they never reach a .pyc -- marshal
; has no writer -- and op_meta's rows for them stay all-zero, so a specialized
; opcode must occupy EXACTLY as many bytes as the generic one it replaced.
;
; The specialized opcodes that predate this block are still written as bare
; literals at their handlers; these are named because five new numbers spread
; across three files is how a wrong one gets introduced.
OP_BINARY_SUBSCR_LIST_INT    equ 235
OP_BINARY_SUBSCR_TUPLE_INT   equ 236
OP_STORE_SUBSCR_LIST_INT     equ 237
OP_UNPACK_SEQUENCE_TUPLE     equ 238
OP_UNPACK_SEQUENCE_LIST      equ 239
OP_STORE_ATTR_INSTANCE       equ 240
OP_CALL_PY_EXACT             equ 241
OP_LOAD_ATTR_PROPERTY        equ 242
OP_STORE_ATTR_SLOT           equ 243

; MAKE_FUNCTION flags
MAKE_FUNC_DEFAULTS  equ 0x01
MAKE_FUNC_KWDEFAULTS equ 0x02
MAKE_FUNC_ANNOTATIONS equ 0x04
MAKE_FUNC_CLOSURE   equ 0x08

; co_flags constants (CPython 3.12).  CO_VARARGS and CO_VARKEYWORDS used to be
; defined privately in src/pyo/func.asm; the compiler has to set them, and two
; independent definitions of the same constant is how a silent one-slot argument
; offset gets introduced.  One definition, here.
CO_OPTIMIZED        equ 0x01
CO_NEWLOCALS        equ 0x02
CO_VARARGS          equ 0x04
CO_VARKEYWORDS      equ 0x08
CO_NESTED           equ 0x10
CO_GENERATOR        equ 0x20
CO_COROUTINE        equ 0x80
CO_ITERABLE_COROUTINE equ 0x100
CO_ASYNC_GENERATOR  equ 0x200
; PEP 563.  Set on every code object compiled from a file that said
; `from __future__ import annotations`, and read back by compile() and exec()
; so that a source compiled from inside such a file inherits it -- which is
; CPython's rule, and the reason the flag is on the CODE rather than only in
; the compiler.
CO_FUTURE_ANNOTATIONS equ 0x1000000
CO_FUTURE_BARRY_AS_BDFL equ 0x400000

; CALL_INTRINSIC_1 / _2 selectors, matching CPython 3.12's intrinsics table.
INTRINSIC_1_INVALID          equ 0
INTRINSIC_PRINT              equ 1
INTRINSIC_IMPORT_STAR        equ 2
INTRINSIC_STOPITERATION_ERROR equ 3
INTRINSIC_ASYNC_GEN_WRAP     equ 4
INTRINSIC_UNARY_POSITIVE     equ 5
INTRINSIC_LIST_TO_TUPLE      equ 6
INTRINSIC_TYPEVAR            equ 7
INTRINSIC_PARAMSPEC          equ 8
INTRINSIC_TYPEVARTUPLE       equ 9
INTRINSIC_SUBSCRIPT_GENERIC  equ 10
INTRINSIC_TYPEALIAS          equ 11

; CALL_INTRINSIC_2 selectors.
INTRINSIC_PREP_RERAISE_STAR  equ 1

; co_localspluskinds bytes.  apython never reads this field, but emitting it
; correctly costs nothing and keeps introspection honest if it is ever wired up.
CO_FAST_LOCAL       equ 0x20
CO_FAST_CELL        equ 0x40
CO_FAST_FREE        equ 0x80

%endif ; OPCODES_INC
