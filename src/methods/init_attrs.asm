; init_attrs.asm - publishing the attributes a tp_getattr already answers.
;
; dir() sees exactly a type's tp_dict over the MRO plus the instance dict, so
; an attribute answered only by a tp_getattr can never appear in one -- and
; neither can it be reached through the TYPE, which is how a great deal of the
; standard library asks.  inspect.getmembers walks dir(); pydoc walks dir();
; unittest.mock's autospec walks dir(); `type(FunctionType.__code__)` is how
; types.py names GetSetDescriptorType.  An exception did not list `args`, a
; function did not list `__name__`, a frame did not list `f_back`, and a code
; object listed none of its sixteen co_* at all -- code_type had no tp_dict
; whatsoever.
;
; The mechanism already existed and was built for exactly this:
; dict_add_getattr makes a read-only getset descriptor whose getter IS the
; whole tp_getattr and stamps GS_NAMED, so the descriptor carries the name it
; was registered under and the one function serves every name it knows.
; methods/init.asm uses it for memoryview's twelve.  This is the same thing for
; the five types that had the most missing, in a table rather than five blocks,
; and in its own file because init.asm is within two kilobytes of the
; hand-written 100k cap.
;
; ONLY a name the row's getattr actually answers may be listed.  A getset whose
; getter returns NULL for its own name raises where the caller expected a miss,
; and `__doc__` on builtin_function_or_method -- which builtin_func_getattr
; does not know -- took the interpreter down before it finished starting.
;
; It publishes; it does not implement.  Every name here already read correctly
; off an instance, and what changes is that the type admits to having it.  The
; one exception is builtin_function_or_method's __self__, which is a genuine
; gap: an UNBOUND builtin answered AttributeError where CPython answers the
; module it belongs to, and that is fixed in builtins.asm rather than here.

%include "macros.inc"
%include "object.inc"

extern add_new_staticmethod
extern dict_new
extern dict_add_getattr
extern dict_add_builtin_func
extern type_stamp_methods
extern dict_view_reversed
extern dict_keys_view_type
extern dict_values_view_type
extern dict_items_view_type
extern ellipsis_type
extern notimpl_type
extern ellipsis_reduce
extern notimpl_reduce

section .text

;; ============================================================================
;; attr_types_init() -> nothing; five types gain the names their getattr knows
;;
;; Called from methods_init, after the types it names are in place.  A type
;; that already HAS a tp_dict is added to rather than replaced -- func_type and
;; the exception base both have one, and building a second would drop
;; everything already in it.
;; ============================================================================
ATI_IDX   equ 8
ATI_DICT  equ 16
ATI_ROW   equ 24
ATI_NAME  equ 32
ATI_FRAME equ 40            ; + 1 push = 48, 16-aligned

global attr_types_init
DEF_FUNC attr_types_init, ATI_FRAME
    push rbx

    ; The three dict views get __reversed__ here rather than in a table of
    ; their own: `reversed(d.keys())` was "'dict_keys' object is not
    ; reversible", though the dict itself has had one all along and the
    ; reverse iterator already carries the kind that tells the three apart.
    call dict_view_add_reversed
    call sre_add_class_getitem
    call singleton_add_reduce

    mov qword [rbp - ATI_IDX], 0

.ati_type_loop:
    mov rax, [rbp - ATI_IDX]
    cmp rax, ATTR_TYPE_COUNT
    jge .ati_done

    imul rax, rax, ATTR_ROW_SIZE
    lea rbx, [rel attr_type_table]
    add rbx, rax
    mov [rbp - ATI_ROW], rbx

    ; The type's dict, made where there is none.
    mov rax, [rbx + ATTR_ROW_TYPE]
    mov rax, [rax + PyTypeObject.tp_dict]
    test rax, rax
    jnz .ati_have_dict
    call dict_new
    mov rbx, [rbp - ATI_ROW]
    mov rcx, [rbx + ATTR_ROW_TYPE]
    mov [rcx + PyTypeObject.tp_dict], rax
.ati_have_dict:
    mov [rbp - ATI_DICT], rax

    ; Each name in the row's list, through the row's own tp_getattr.
    mov qword [rbp - ATI_NAME], 0
.ati_name_loop:
    mov rbx, [rbp - ATI_ROW]
    mov rcx, [rbp - ATI_NAME]
    cmp rcx, [rbx + ATTR_ROW_COUNT]
    jge .ati_names_done
    mov rax, [rbx + ATTR_ROW_NAMES]
    mov rsi, [rax + rcx*8]
    mov rdi, [rbp - ATI_DICT]
    mov rdx, [rbx + ATTR_ROW_GETATTR]
    call dict_add_getattr
    inc qword [rbp - ATI_NAME]
    jmp .ati_name_loop

.ati_names_done:
    ; type_stamp_methods walks the dict and gives every entry its func_owner.
    ; A getset descriptor is not a builtin function and is left alone, which is
    ; why methods/init.asm can call it after memoryview's twelve.
    mov rbx, [rbp - ATI_ROW]
    mov rdi, [rbx + ATTR_ROW_TYPE]
    call type_stamp_methods

    inc qword [rbp - ATI_IDX]
    jmp .ati_type_loop

.ati_done:
    pop rbx
    leave
    ret
END_FUNC attr_types_init


;; ============================================================================
;; singleton_add_reduce() -> nothing; Ellipsis and NotImplemented gain
;; __reduce__
;;
;; Neither type had a tp_dict at all, so both inherited object.__reduce__ and
;; were refused by pickle.  CPython answers with the NAME, which pickle
;; resolves as a global in builtins -- the two singletons are the only objects
;; reduced that way.  Here rather than in methods/init.asm because that file
;; is at the hand-written 100k cap.
;; ============================================================================
SAR_FRAME equ 24            ; + 1 push = 32, 16-aligned
DEF_FUNC_LOCAL singleton_add_reduce, SAR_FRAME
    push rbx
    call dict_new
    mov rbx, rax
    mov rdi, rbx
    lea rsi, [rel an_reduce]
    lea rdx, [rel ellipsis_reduce]
    call dict_add_builtin_func
    ; EllipsisType keeps its constructor in tp_new; without an entry here
    ; `EllipsisType.__new__` resolved to object.__new__ and was refused.
    extern ellipsis_dunder_new
    mov rdi, rbx
    lea rsi, [rel ellipsis_dunder_new]
    call add_new_staticmethod
    lea rax, [rel ellipsis_type]
    mov [rax + PyTypeObject.tp_dict], rbx
    mov rdi, rax
    call type_stamp_methods

    call dict_new
    mov rbx, rax
    mov rdi, rbx
    lea rsi, [rel an_reduce]
    lea rdx, [rel notimpl_reduce]
    call dict_add_builtin_func
    ; NotImplementedType keeps its constructor in tp_new; without an entry here
    ; `NotImplementedType.__new__` resolved to object.__new__ and was refused.
    extern notimpl_dunder_new
    mov rdi, rbx
    lea rsi, [rel notimpl_dunder_new]
    call add_new_staticmethod
    lea rax, [rel notimpl_type]
    mov [rax + PyTypeObject.tp_dict], rbx
    mov rdi, rax
    call type_stamp_methods

    ; NoneType has no tp_dict either, and its nb_bool could not be reached by
    ; name.  __reduce__ is not among these: None pickles as a type code, not
    ; through the reduction protocol.
    call dict_new
    mov rbx, rax
    mov rdi, rbx
    lea rsi, [rel an_bool]
    extern none_dunder_bool
    lea rdx, [rel none_dunder_bool]
    call dict_add_builtin_func
    extern none_type
    ; NoneType keeps its constructor in tp_new; without an entry here
    ; `NoneType.__new__` resolved to object.__new__ and was refused.
    extern none_dunder_new
    mov rdi, rbx
    lea rsi, [rel none_dunder_new]
    call add_new_staticmethod
    lea rax, [rel none_type]
    mov [rax + PyTypeObject.tp_dict], rbx
    mov rdi, rax
    call type_stamp_methods
    pop rbx
    leave
    ret
END_FUNC singleton_add_reduce

;; ============================================================================
;; dict_view_add_reversed() -> nothing; the three views gain __reversed__
;;
;; Their tp_dicts are made by repr_types_init, which runs first, so there is
;; one to add into.
;; ============================================================================
DVA_IDX   equ 8
DVA_FRAME equ 24            ; + 1 push = 32, 16-aligned
DEF_FUNC_LOCAL dict_view_add_reversed, DVA_FRAME
    push rbx
    mov qword [rbp - DVA_IDX], 0
.dva_loop:
    mov rax, [rbp - DVA_IDX]
    cmp rax, 3
    jge .dva_done
    lea rcx, [rel dict_view_types]
    mov rbx, [rcx + rax*8]
    mov rax, [rbx + PyTypeObject.tp_dict]
    test rax, rax
    jnz .dva_have
    call dict_new
    mov [rbx + PyTypeObject.tp_dict], rax
.dva_have:
    mov rdi, rax
    push rax
    lea rsi, [rel an_reversed]
    lea rdx, [rel dict_view_reversed]
    call dict_add_builtin_func
    ; .mapping is on all three; .isdisjoint only on the two that are set-like,
    ; which is the order dict_view_types is in.
    mov rdi, [rsp]
    lea rsi, [rel an_mapping]
    extern dict_view_get_mapping
    lea rdx, [rel dict_view_get_mapping]
    xor ecx, ecx
    extern dict_add_getset
    call dict_add_getset
    pop rdi
    cmp qword [rbp - DVA_IDX], 1
    je .dva_stamp
    lea rsi, [rel an_isdisjoint]
    extern dict_view_isdisjoint
    lea rdx, [rel dict_view_isdisjoint]
    call dict_add_builtin_func
.dva_stamp:
    mov rdi, rbx
    call type_stamp_methods
    inc qword [rbp - DVA_IDX]
    jmp .dva_loop
.dva_done:
    pop rbx
    leave
    ret
END_FUNC dict_view_add_reversed

;; ============================================================================
;; sre_add_class_getitem() -> nothing; re.Match and re.Pattern become
;; subscriptable
;;
;; PEP 585 on the two regex types: `re.Match[str]` and `re.Pattern[bytes]` are
;; what a typed stdlib writes, and `test_clinic` reads `re.Match[str]` at
;; module scope -- so its absence aborted the whole file.  Neither type has a
;; tp_dict of its own, so one is made here; nothing else needs one.
;; ============================================================================
SCG_IDX   equ 8
SCG_FRAME equ 24            ; + 1 push = 32, 16-aligned
DEF_FUNC_LOCAL sre_add_class_getitem, SCG_FRAME
    push rbx
    mov qword [rbp - SCG_IDX], 0
.scg_loop:
    mov rax, [rbp - SCG_IDX]
    cmp rax, 2
    jge .scg_done
    lea rcx, [rel sre_subscriptable_types]
    mov rbx, [rcx + rax*8]
    mov rax, [rbx + PyTypeObject.tp_dict]
    test rax, rax
    jnz .scg_have
    call dict_new
    mov [rbx + PyTypeObject.tp_dict], rax
.scg_have:
    mov rdi, rax
    extern add_class_getitem
    call add_class_getitem
    mov rdi, rbx
    call type_stamp_methods
    inc qword [rbp - SCG_IDX]
    jmp .scg_loop
.scg_done:
    pop rbx
    leave
    ret
END_FUNC sre_add_class_getitem

section .rodata
an_reversed:  db "__reversed__", 0
an_mapping:   db "mapping", 0
an_isdisjoint: db "isdisjoint", 0
an_reduce:    db "__reduce__", 0
an_bool:      db "__bool__", 0

align 8
dict_view_types:
    dq dict_keys_view_type, dict_values_view_type, dict_items_view_type

align 8
extern sre_match_type
extern sre_pattern_type
sre_subscriptable_types:
    dq sre_match_type, sre_pattern_type

; --- exceptions: what exc_getattr answers -----------------------------------
; sorted(dir(ValueError(1))) was short of every one of these, so
; inspect.getmembers(e) came back with 26 entries against CPython's 33.
an_args:              db "args", 0
an_traceback:         db "__traceback__", 0
an_cause:             db "__cause__", 0
an_context:           db "__context__", 0
an_suppress:          db "__suppress_context__", 0

align 8
; __notes__ is deliberately absent: PEP 678 creates it on the first add_note()
; and CPython's dir() does not list it before then either.
exc_attr_names:
    dq an_args, an_traceback, an_cause, an_context, an_suppress
EXC_ATTR_COUNT equ ($ - exc_attr_names) / 8

; --- functions: what func_getattr answers -----------------------------------
; __code__ and __globals__ are deliberately NOT here: methods/init.asm gives
; those two hand-made descriptors, because types.py takes
; GetSetDescriptorType and MemberDescriptorType from their types and each has
; to be a particular kind.
an_f_name:      db "__name__", 0
an_f_qualname:  db "__qualname__", 0
an_f_defaults:  db "__defaults__", 0
an_f_kwdefaults: db "__kwdefaults__", 0
an_f_closure:   db "__closure__", 0
an_f_annotations: db "__annotations__", 0
an_f_module:    db "__module__", 0
an_f_doc:       db "__doc__", 0
an_f_dict:      db "__dict__", 0

align 8
func_attr_names:
    dq an_f_name, an_f_qualname, an_f_defaults, an_f_kwdefaults, an_f_closure
    dq an_f_annotations, an_f_module, an_f_doc, an_f_dict
FUNC_ATTR_COUNT equ ($ - func_attr_names) / 8

; --- frames: what frameobj_getattr answers ----------------------------------
an_fr_back:     db "f_back", 0
an_fr_code:     db "f_code", 0
an_fr_globals:  db "f_globals", 0
an_fr_builtins: db "f_builtins", 0
an_fr_locals:   db "f_locals", 0
an_fr_lineno:   db "f_lineno", 0
an_fr_lasti:    db "f_lasti", 0
an_fr_trace:    db "f_trace", 0
an_fr_tlines:   db "f_trace_lines", 0
an_fr_topcodes: db "f_trace_opcodes", 0

align 8
frame_attr_names:
    dq an_fr_back, an_fr_code, an_fr_globals, an_fr_builtins, an_fr_locals
    dq an_fr_lineno, an_fr_lasti, an_fr_trace, an_fr_tlines, an_fr_topcodes
FRAME_ATTR_COUNT equ ($ - frame_attr_names) / 8

; --- code objects: what code_getattr answers --------------------------------
; code_type had NO tp_dict at all, so dir(f.__code__) listed object's dunders
; and nothing else -- and dis.py reads co_* off the type in places.
an_co_name:     db "co_name", 0
an_co_qualname: db "co_qualname", 0
an_co_filename: db "co_filename", 0
an_co_consts:   db "co_consts", 0
an_co_names:    db "co_names", 0
an_co_lpnames:  db "co_localsplusnames", 0
an_co_varnames: db "co_varnames", 0
an_co_cellvars: db "co_cellvars", 0
an_co_freevars: db "co_freevars", 0
an_co_firstln:  db "co_firstlineno", 0
an_co_flags:    db "co_flags", 0
an_co_nlocals:  db "co_nlocals", 0
an_co_stacksize: db "co_stacksize", 0
an_co_argcount: db "co_argcount", 0
an_co_posonly:  db "co_posonlyargcount", 0
an_co_kwonly:   db "co_kwonlyargcount", 0
an_co_linetable: db "co_linetable", 0
an_co_exctable: db "co_exceptiontable", 0
an_co_code:     db "co_code", 0

align 8
code_attr_names:
    dq an_co_name, an_co_qualname, an_co_filename, an_co_consts, an_co_names
    dq an_co_lpnames, an_co_varnames, an_co_cellvars, an_co_freevars
    dq an_co_firstln, an_co_flags, an_co_nlocals, an_co_stacksize
    dq an_co_argcount, an_co_posonly, an_co_kwonly, an_co_linetable
    dq an_co_exctable, an_co_code
CODE_ATTR_COUNT equ ($ - code_attr_names) / 8

; --- builtin functions: what builtin_func_getattr answers -------------------
an_b_name:      db "__name__", 0
an_b_qualname:  db "__qualname__", 0
an_b_module:    db "__module__", 0
an_b_self:      db "__self__", 0

align 8
builtin_attr_names:
    dq an_b_name, an_b_qualname, an_b_module, an_b_self
BUILTIN_ATTR_COUNT equ ($ - builtin_attr_names) / 8

ATTR_ROW_TYPE    equ 0
ATTR_ROW_GETATTR equ 8
ATTR_ROW_NAMES   equ 16
ATTR_ROW_COUNT   equ 24
ATTR_ROW_SIZE    equ 32

%macro ATTR_ROW 4               ; type, getattr fn, names label, count
    extern %1
    extern %2
    dq %1, %2, %3, %4
%endmacro

align 8
attr_type_table:
    ATTR_ROW exc_BaseException_type, exc_getattr,         exc_attr_names,     EXC_ATTR_COUNT
    ATTR_ROW func_type,              func_getattr,        func_attr_names,    FUNC_ATTR_COUNT
    ATTR_ROW frame_object_type,      frameobj_getattr,    frame_attr_names,   FRAME_ATTR_COUNT
    ATTR_ROW code_type,              code_getattr,        code_attr_names,    CODE_ATTR_COUNT
    ATTR_ROW builtin_func_type,      builtin_func_getattr, builtin_attr_names, BUILTIN_ATTR_COUNT
    ATTR_ROW builtin_descr_type,     builtin_func_getattr, builtin_attr_names, BUILTIN_ATTR_COUNT - 1
ATTR_TYPE_COUNT equ ($ - attr_type_table) / ATTR_ROW_SIZE
