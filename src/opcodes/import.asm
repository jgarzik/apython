; opcodes/import.asm - IMPORT_NAME and IMPORT_FROM opcode handlers

%include "macros.inc"
%include "object.inc"

extern eval_dispatch
extern eval_saved_r13
extern import_module
extern obj_decref
extern raise_exception
extern exc_ImportError_type
extern exc_raise_import
extern dict_get
extern str_from_cstr_heap
extern str_type
extern eval_co_names
extern eval_saved_rbx
extern obj_dealloc
extern opcode_table
extern opcode_dispatch_table

;; ============================================================================
;; op_import_name - Opcode 108: IMPORT_NAME
;;
;; Stack in: [level, fromlist] (TOS = fromlist, TOS1 = level)
;; Stack out: [module]
;;
;; ecx = arg = index into co_names for module name
;; ============================================================================
DEF_FUNC_BARE op_import_name
    ; Get module name from co_names[ecx] (payload array: 8-byte stride)
    shl ecx, 3
    LOAD_CO_NAMES rax
    mov rax, [rax + rcx]       ; name_str from co_names

    ; Pop fromlist (TOS)
    VPOP_VAL rsi, r8            ; fromlist payload+tag

    ; Pop level (TOS1)
    VPOP_VAL rdx, rcx           ; level payload+tag

    ; Save name, fromlist (payload+tag), and level for later.  FOUR pushes,
    ; deliberately: a handler is jumped to rather than called, so rsp arrives
    ; 16-aligned and every call below has to be made at an even push count.
    push rax                    ; name
    push r8                     ; fromlist tag
    push rsi                    ; fromlist payload
    push rdx                    ; level

    ; The two operands are ours now.  eval_saved_r13 was captured by
    ; eval_dispatch *before* those pops, so a non-local unwind out of
    ; import_module would have walked the value stack back down over both
    ; slots and DECREF'd them a second time -- a double free of the
    ; fromlist tuple on every failing import.
    mov [rel eval_saved_r13], r13

    ; Decode level from SmallInt
    cmp ecx, TAG_SMALLINT
    je .decode_smallint
    ; Not a SmallInt — assume 0
    xor edx, edx
    jmp .do_import

.decode_smallint:
    ; rdx already holds the raw integer payload (no decoding needed for fat values)

.do_import:
    ; A relative import is resolved against the importing module's package
    ; before anything else happens; import_module only knows absolute names.
    test rdx, rdx
    jz .absolute
    push rax
    sub rsp, 8                  ; pad: an odd push makes the call below odd
    mov rdi, rax                ; the name as written
    mov rsi, [r12 + PyFrame.globals]
    extern import_resolve_relative
    call import_resolve_relative
    mov rdx, rax                ; the resolved name, owned
    add rsp, 8
    pop rax
    mov [rsp + 24], rdx         ; keep it where the saved name lives
    mov rax, rdx
    xor edx, edx                    ; it is absolute now
    mov r15d, 1                 ; and the name is ours to release
    jmp .have_name
.absolute:
    xor r15d, r15d
.have_name:
    ; The flag lives in r15, which the register convention leaves free for a
    ; handler and which is callee-saved, so it survives import_module.  It
    ; used to be a FIFTH push, and that is what misaligned this call -- and
    ; with it every frame the imported module ran, since the misalignment
    ; propagates down the whole nested interpreter stack.

    ; import_module(name_str, fromlist, level)
    mov rdi, rax                ; name
    mov rsi, [rsp + 8]          ; fromlist
    ; rdx = level (already set)
    call import_module
    ; rax = module (new reference)

    test r15d, r15d
    jz .no_resolved_name
    push rax
    sub rsp, 8                  ; pad, as above
    mov rdi, [rsp + 40]         ; the resolved name we built
    call obj_decref
    add rsp, 8
    pop rax
.no_resolved_name:

    add rsp, 8                  ; discard level (SmallInt, no refcount)

    ; DECREF fromlist (may be None/TAG_NONE — use fat DECREF_VAL)
    pop rdi                     ; fromlist payload
    pop rsi                     ; fromlist tag
    push rax                    ; save module across DECREF
    DECREF_VAL rdi, rsi
    pop rax                     ; restore module

    add rsp, 8                  ; pop saved name (borrowed ref, no DECREF)

    ; Push module onto value stack
    test rax, rax
    jz .import_failed
    VPUSH_PTR rax
    DISPATCH

.import_failed:
    ; import_module raises for a module it cannot find, but returns NULL for
    ; one whose body raised -- that exception is already pending and must be
    ; propagated, not replaced.
    extern current_exception
    extern eval_exception_unwind
    cmp qword [rel current_exception], 0
    jne .propagate_import_exc
    RAISE exc_ImportError_type, "import failed"

.propagate_import_exc:
    mov [rel eval_saved_r13], r13
    jmp eval_exception_unwind
END_FUNC op_import_name


;; ============================================================================
;; import_module_dict(rdi = an object) -> rax = its mod_dict, or 0 when the
;;   object is not a module
;;
;; sys.modules is an ordinary dict and a program may put anything in it --
;; importlib's own import_fresh_module does.  Reading mod_dict off whatever
;; was there handed dict_get a field that belongs to some other struct: a
;; string's characters, in the crash that found this.
;; ============================================================================
extern module_type
DEF_FUNC_BARE import_module_dict
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel module_type]
    cmp rax, rcx
    je .imd_yes
    ; A ModuleType SUBCLASS is a module too, and lib/ ships one.
    push rdi
    mov rdi, rax
    mov rsi, rcx
    extern type_is_subtype
    call type_is_subtype
    pop rdi
    test eax, eax
    jz .imd_no
.imd_yes:
    mov rax, [rdi + PyModuleObject.mod_dict]
    ret
.imd_no:
    xor eax, eax
    ret
END_FUNC import_module_dict

;; ============================================================================
;; op_import_from - Opcode 109: IMPORT_FROM
;;
;; Stack in: [module] (TOS = module, NOT popped)
;; Stack out: [module, attr]
;;
;; ecx = arg = index into co_names for attribute name
;;
;; If attr not found on module, tries importing <pkg_name>.<attr_name>
;; as a submodule (CPython submodule fallback).
;; ============================================================================
extern dict_get
extern dict_set
extern obj_incref
extern str_from_cstr_heap
extern str_concat
extern import_find_and_load

IF_ATTR  equ 8
IF2_MOD  equ 16
IF2_SUB  equ 24             ; the submodule the fallback loaded
IF2_T1   equ 40             ; the two temporaries the dotted-name concat used
IF2_T2   equ 48             ; to push and pop one at a time
IF2_FRAME equ 56            ; 40 was the aligned size; +16 keeps the parity

DEF_FUNC op_import_from, IF2_FRAME
    ; Get attribute name from co_names[ecx] (payload array: 8-byte stride)
    shl ecx, 3
    LOAD_CO_NAMES rsi
    mov rsi, [rsi + rcx]       ; attr name_str
    mov [rbp - IF_ATTR], rsi

    ; Peek module (TOS, don't pop)
    VPEEK rdi
    mov [rbp - IF2_MOD], rdi

    ; Anything but an exact module -- six.moves is a ModuleType SUBCLASS
    ; whose names are lazy descriptors on the class -- takes the whole
    ; attribute protocol, as `obj.name` does; tp_getattr alone handed back
    ; the descriptor itself.  CPython's import_from is PyObject_GetAttr.
    mov rax, [rdi + PyObject.ob_type]
    extern module_type
    lea rcx, [rel module_type]
    cmp rax, rcx
    je .if_plain_module
    V_TEST_PTR rdi, rcx
    ja .if_plain_module
    extern obj_getattr_opt
    call obj_getattr_opt
    test rax, rax
    jz .if_try_submodule
    VPUSH rax
    leave
    DISPATCH
.if_plain_module:
    mov rdi, [rbp - IF2_MOD]
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_getattr]
    test rax, rax
    jz .if_no_getattr

    ; Call tp_getattr(module, name_str)
    call rax
    V_UNPACK rax, rdx           ; tp_getattr returns a Value
    test edx, edx
    jnz .if_got_attr

    ; tp_getattr returned NULL -- try dict_get directly.  A module's PEP 562
    ; __getattr__ reports "absent" by raising AttributeError, and CPython's
    ; import_from swallows that before trying the submodule of the same name:
    ; `from pkg import sub` must reach the submodule, not report what the hook
    ; said about a name that was never meant to be an attribute.
    extern import_clear_attr_error
    call import_clear_attr_error
    mov rdi, [rbp - IF2_MOD]
    call import_module_dict
    mov rdi, rax
    test rdi, rdi
    jz .if_try_submodule
    mov rsi, [rbp - IF_ATTR]
    call dict_get
    V_UNPACK rax, rdx           ; dict_get returns a Value
    test edx, edx
    jnz .if_found_in_dict
    jmp .if_try_submodule

.if_no_getattr:
    ; No tp_getattr — try dict_get on module dict
    mov rdi, [rbp - IF2_MOD]
    call import_module_dict
    mov rdi, rax
    test rdi, rdi
    jz .if_try_submodule
    mov rsi, [rbp - IF_ATTR]
    call dict_get
    V_UNPACK rax, rdx           ; dict_get returns a Value
    test edx, edx
    jnz .if_found_in_dict
    jmp .if_try_submodule

.if_found_in_dict:
    INCREF_VAL rax, edx
    VPUSH_VAL rax, rdx
    leave
    DISPATCH

.if_got_attr:
    VPUSH_VAL rax, rdx
    leave
    DISPATCH

.if_try_submodule:
    ; Submodule fallback: construct "<pkg_name>.<attr_name>" and try importing
    ; Get module's __name__ from its dict
    mov rdi, [rbp - IF2_MOD]
    mov rdi, [rdi + PyModuleObject.mod_dict]
    test rdi, rdi
    jz .if_error

    ; The attribute is not there, so it may be a SUBMODULE the package's own
    ; body never bound.  import_submodule_attr builds the dotted name, loads
    ; it, and binds it on the package -- which is also what IMPORT_STAR needs,
    ; and used not to have.
    mov rdi, [rbp - IF2_MOD]
    mov rsi, [rbp - IF_ATTR]
    extern import_submodule_attr
    call import_submodule_attr
    test rax, rax
    jz .if_error
    mov [rbp - IF2_SUB], rax

    ; import_find_and_load hands back a BORROWED reference -- sys.modules owns
    ; it -- and the value stack owns what it holds.
    mov rdi, [rbp - IF2_SUB]
    call obj_incref
    mov rax, [rbp - IF2_SUB]
    VPUSH_PTR rax
    leave
    DISPATCH

.if_error:
    ; A submodule whose body raised leaves its exception pending; reporting
    ; "cannot import name" over it would hide the real cause.
    cmp qword [rel current_exception], 0
    jne .propagate_from_exc
    mov [rel eval_saved_r13], r13
    mov rdi, [rbp - IF2_MOD]
    mov rsi, [rbp - IF_ATTR]
    call import_from_error
    ud2

.propagate_from_exc:
    mov [rel eval_saved_r13], r13
    leave
    jmp eval_exception_unwind
END_FUNC op_import_from

section .rodata
if_dunder_name: db "__name__", 0
if_dot_str: db ".", 0
section .text

;; ============================================================================
;; import_from_error(rdi = the module, rsi = the attribute name str)
;;     -- does not return
;;
;; CPython's ceval.c import_from names the attribute, the module, and where
;; the module came from:
;;
;;     cannot import name 'X' from 'm' (/path/to/m.py)
;;     cannot import name 'X' from 'm' (unknown location)
;;     cannot import name 'X' from '<unknown module name>' (unknown location)
;;
;; and sets .name to the module's __name__ and .path to its __file__, which is
;; how a caller distinguishes "no such module" from "that module has no such
;; name".  We raised a bare "cannot import name" with neither in it.
;;
;; The fourth CPython wording -- "from partially initialized module 'm' (most
;; likely due to a circular import)" -- is not reachable here: it is decided by
;; __spec__._initializing, and our modules carry __spec__ = None.  bugs.md.
;;
;; %R of a str is its repr, but every name that can appear in an import
;; statement is an identifier and every __name__ a dotted one, so plain quotes
;; are exactly CPython's output rather than an approximation of it.
;; ============================================================================
IFE_ATTR  equ 8
IFE_MOD   equ 16
IFE_NAME  equ 24                ; __name__, if it is a str
IFE_PATH  equ 32                ; __file__, if it is a str
IFE_CAP   equ 1024
IFE_BUF   equ 32 + IFE_CAP
IFE_FRAME equ IFE_BUF           ; + 0 pushes, and IFE_BUF is a multiple of 16
DEF_FUNC_LOCAL import_from_error, IFE_FRAME
    mov [rbp - IFE_MOD], rdi
    mov [rbp - IFE_ATTR], rsi
    mov qword [rbp - IFE_NAME], 0
    mov qword [rbp - IFE_PATH], 0

    mov rdi, [rbp - IFE_MOD]
    call import_module_dict
    test rax, rax
    jz .ife_build
    mov [rbp - IFE_MOD], rax        ; the dict from here on

    mov rdi, rax
    CSTRING rsi, "__name__"
    call ife_str_field
    mov [rbp - IFE_NAME], rax
    mov rdi, [rbp - IFE_MOD]
    CSTRING rsi, "__file__"
    call ife_str_field
    mov [rbp - IFE_PATH], rax

.ife_build:
    lea rdi, [rbp - IFE_BUF]
    xor ecx, ecx
    CSTRING rdx, "cannot import name '"
    call ife_cat_z
    mov rdx, [rbp - IFE_ATTR]
    call ife_cat_str
    CSTRING rdx, "' from '"
    call ife_cat_z
    mov rdx, [rbp - IFE_NAME]
    test rdx, rdx
    jz .ife_no_name
    call ife_cat_str
    jmp .ife_after_name
.ife_no_name:
    CSTRING rdx, "<unknown module name>"
    call ife_cat_z
.ife_after_name:
    CSTRING rdx, "' ("
    call ife_cat_z
    mov rdx, [rbp - IFE_PATH]
    test rdx, rdx
    jz .ife_no_path
    call ife_cat_str
    jmp .ife_after_path
.ife_no_path:
    CSTRING rdx, "unknown location"
    call ife_cat_z
.ife_after_path:
    CSTRING rdx, ")"
    call ife_cat_z
    mov byte [rdi + rcx], 0

    lea rdi, [rel exc_ImportError_type]
    lea rsi, [rbp - IFE_BUF]
    mov rdx, [rbp - IFE_NAME]
    mov rcx, [rbp - IFE_PATH]
    xor r8d, r8d                    ; both borrowed from the module dict
    call exc_raise_import
    ud2
END_FUNC import_from_error

;; ============================================================================
;; ife_str_field(rdi = a dict, rsi = key C string) -> rax = the value when it
;;     is a str, else 0
;;
;; A non-str answers 0, because CPython requires a str for both __name__ and
;; __file__ and falls back to its "unknown" wording otherwise -- a module whose
;; __file__ someone set to an int must not reach the message builder as a
;; pointer.
;; ============================================================================
ISF_DICT  equ 8
ISF_KEY   equ 16
ISF_FRAME equ 40                ; + 1 push = 48, 16-aligned
DEF_FUNC_LOCAL ife_str_field, ISF_FRAME
    push rbx
    mov [rbp - ISF_DICT], rdi
    mov rdi, rsi
    call str_from_cstr_heap
    test rax, rax
    jz .isf_none
    mov [rbp - ISF_KEY], rax
    mov rdi, [rbp - ISF_DICT]
    mov rsi, rax
    call dict_get                   ; a Value; 0 is the miss
    mov rbx, rax
    mov rdi, [rbp - ISF_KEY]
    call obj_decref
    test rbx, rbx
    jz .isf_none
    V_TEST_PTR rbx, rax
    ja .isf_none                    ; an immediate is not a str
    mov rax, [rbx + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    jne .isf_none
    mov rax, rbx
    pop rbx
    leave
    ret
.isf_none:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC ife_str_field

;; ============================================================================
;; ife_cat_str(rdi = buffer, rcx = offset, rdx = a PyStrObject) -> rcx advanced
;;
;; Clobbers rax, rsi, r8 and rdx only.  rdi and rcx are the running buffer and
;; offset the caller keeps across a whole run of these, and every other
;; register it holds survives -- the message builder relies on that.
;; ============================================================================
DEF_FUNC_BARE ife_cat_str
    mov rsi, [rdx + PyStrObject.ob_size]
    lea rdx, [rdx + PyStrObject.data]
    jmp ife_cat_n
END_FUNC ife_cat_str

;; ============================================================================
;; ife_cat_z(rdi = buffer, rcx = offset, rdx = NUL-terminated source)
;;     -> rcx advanced.  Same register contract as ife_cat_str.
;; ============================================================================
DEF_FUNC_BARE ife_cat_z
    xor esi, esi
.measure:
    cmp byte [rdx + rsi], 0
    je ife_cat_n
    inc rsi
    jmp .measure
END_FUNC ife_cat_z

;; ============================================================================
;; ife_cat_n(rdi = buffer, rcx = offset, rdx = source, rsi = length)
;;     -> rcx advanced.  Same register contract as ife_cat_str.
;;
;; Stops at IFE_CAP - 8, leaving room for the closing ")" and the NUL that
;; import_from_error writes unconditionally, so a very long __file__ truncates
;; the path rather than the message's shape.
;; ============================================================================
DEF_FUNC_BARE ife_cat_n
    xor eax, eax
.loop:
    cmp rax, rsi
    jae .done
    cmp rcx, IFE_CAP - 8
    jae .done
    mov r8b, [rdx + rax]
    mov [rdi + rcx], r8b
    inc rax
    inc rcx
    jmp .loop
.done:
    ret
END_FUNC ife_cat_n
