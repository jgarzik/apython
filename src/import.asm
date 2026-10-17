; import.asm - Import machinery for apython
; Handles IMPORT_NAME / IMPORT_FROM opcodes and module loading

%include "macros.inc"
%include "object.inc"

extern ap_malloc
extern ap_free
extern ap_memcpy
extern ap_strlen
extern sys_getcwd
extern ap_strcmp
extern ap_memcmp
extern obj_decref
extern obj_incref
extern obj_dealloc
extern str_from_cstr_heap
extern str_new_heap
extern str_type
extern none_singleton
extern module_type
extern obj_call_n
extern exc_raise_import
extern str_from_cstr_heap
extern str_intern_cstr
extern dict_new
extern dict_get
extern dict_set
extern dict_del
extern current_exception
extern attr_error_pending
extern eval_exception_unwind
extern list_new
extern list_append
extern type_type
extern module_new
extern fatal_error
extern raise_exception
extern eval_frame
extern frame_new
extern frame_free
extern code_from_path
extern path_is_source
extern sys_open
extern sys_close
extern sys_read
extern sys_stat

; Marshal globals (save/restore across nested loads)
extern marshal_buf
extern marshal_pos
extern marshal_len
extern marshal_refs
extern marshal_ref_count
extern marshal_ref_cap

; sys module globals
extern sys_modules_dict
extern sys_path_list
extern sys_module_init

; builtins
extern builtins_dict_global
extern exc_ImportError_type
extern exc_ModuleNotFoundError_type
extern str_concat

; Builtin modules

; --- import_module frame layout ---
IF_NAME     equ 8            ; import name str
IF_FROMLIST equ 16           ; fromlist
IF_LEVEL    equ 24           ; level (int)
IF_TOPMOD   equ 32           ; top-level module
IF_MBUF     equ 40           ; saved marshal_buf
IF_MPOS     equ 48           ; saved marshal_pos
IF_MLEN     equ 56           ; saved marshal_len
IF_MREFS    equ 64           ; saved marshal_refs
IF_MRCNT    equ 72           ; saved marshal_ref_count
IF_MRCAP    equ 80           ; saved marshal_ref_cap
IF_EXC      equ 88           ; current_exception on entry (see .import_error)
IF_POS      equ 96           ; byte position while walking a dotted name
IF_PARENT   equ 104          ; the module the next component hangs off
IF_LEAF     equ 112          ; the module the walk has reached
IF_FAILLEN  equ 120          ; length of the prefix to blame in an error
IF_FAILPAR  equ 128          ; length of its parent, when that is the reason
IF_FRAME    equ 136            ; + 5 pushes = 176, 16-aligned

; --- import_find_and_load frame layout ---
; path_component buffer lives on stack below frame locals
FL_NAME     equ 8            ; name_str (PyObject*)
FL_LEAF     equ 16           ; leaf name cstr ptr
FL_LEAFLEN  equ 24           ; leaf name length
FL_FRAME    equ 56            ; + 5 pushes = 96, 16-aligned
FL_STKSZ    equ 4096         ; stack buffer for path component

; Path buffer size
PATHBUF_SIZE equ 8192
; Room for the longest suffix this file appends after the directory and the
; module component: "/__pycache__/__init__.cpython-312.pyc" is 37 bytes.
IM_PATH_MARGIN equ 64

;; ============================================================================
;; import_init(int argc, char **argv)
;; Initialize the import system: sys module + builtins in sys.modules

;; ============================================================================
;; import_add_exe_relative_path(rdi = suffix cstr)
;; Appends <directory of the running binary>/<suffix> to sys.path.  Falls back
;; to the plain relative entry when /proc/self/exe cannot be read.

;; ============================================================================
;; import_resolve_relative(rdi = name str, rsi = globals dict, rdx = level)
;;   -> rax = the absolute name, a new reference
;;
;; `from . import x` inside a package: level counts how far up from the
;; importing module's package to start.  Level was read off the stack and then
;; ignored, so every relative import in the stdlib looked like an import of the
;; empty name.
;; ============================================================================
IRR_NAME  equ 8
IRR_LEVEL equ 16
IRR_PKG   equ 24
IRR_LEN   equ 32
IRR_BUF   equ 1064          ; 1024 bytes, [rbp-1064, rbp-40)
global import_resolve_relative
IRR_FRAME equ 1072          ; + 2 pushes = 1088
DEF_FUNC import_resolve_relative, IRR_FRAME
    push rbx
    push r12
    mov [rbp - IRR_NAME], rdi
    mov [rbp - IRR_LEVEL], rdx

    ; The importing module's package.  __package__ is set at import time; for
    ; a package itself it is the package's own name.
    test rsi, rsi
    jz .irr_no_package
    push rsi
    lea rdi, [rel irr_package_key]
    call str_from_cstr_heap
    mov rbx, rax
    pop rdi
    mov rsi, rbx
    call dict_get
    push rax
    mov rdi, rbx
    call obj_decref
    pop rax
    test rax, rax
    jz .irr_no_package
    V_TEST_PTR rax, rcx
    ja .irr_no_package
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    jne .irr_no_package
    mov [rbp - IRR_PKG], rax
    mov rcx, [rax + PyStrObject.ob_size]
    test rcx, rcx
    jz .irr_no_package

    ; Copy the package name, then drop one trailing component per extra level.
    lea rbx, [rbp - IRR_BUF]
    cmp rcx, IRR_BUF - 64
    jae .irr_no_package
    mov [rbp - IRR_LEN], rcx
    mov rdi, rbx
    mov rax, [rbp - IRR_PKG]
    lea rsi, [rax + PyStrObject.data]
    mov rdx, rcx
    call ap_memcpy

    mov r12, [rbp - IRR_LEVEL]
    dec r12
.irr_strip:
    test r12, r12
    jle .irr_have_base
    mov rcx, [rbp - IRR_LEN]
.irr_find_dot:
    test rcx, rcx
    jz .irr_beyond_top
    dec rcx
    cmp byte [rbx + rcx], '.'
    jne .irr_find_dot
    mov [rbp - IRR_LEN], rcx
    dec r12
    jmp .irr_strip

.irr_have_base:
    ; Append ".name" when there is a name; `from . import x` has none.
    mov rax, [rbp - IRR_NAME]
    mov rdx, [rax + PyStrObject.ob_size]
    test rdx, rdx
    jz .irr_build
    mov rcx, [rbp - IRR_LEN]
    mov byte [rbx + rcx], '.'
    inc rcx
    mov [rbp - IRR_LEN], rcx
    lea rdi, [rbx + rcx]
    lea rsi, [rax + PyStrObject.data]
    push rdx
    call ap_memcpy
    pop rdx
    add [rbp - IRR_LEN], rdx

.irr_build:
    mov rdi, rbx
    mov rsi, [rbp - IRR_LEN]
    call str_new_heap
    pop r12
    pop rbx
    leave
    ret

.irr_beyond_top:
    RAISE exc_ImportError_type, "attempted relative import beyond top-level package"
.irr_no_package:
    RAISE exc_ImportError_type, "attempted relative import with no known parent package"
END_FUNC import_resolve_relative

;; ============================================================================
;; exe_path(rdi = a buffer, rsi = its size) -> rax = the length written, or 0
;;
;; Where this interpreter's binary is, from /proc/self/exe.  NOT from argv[0]:
;; main() shifts argv past `-t`, so argv[0] is sometimes "-t", and a bare
;; "./apython" would not survive a chdir -- which is exactly what a subprocess
;; spawned from a temporary working directory does.
;;
;; The buffer is NOT NUL-terminated by readlink, so the caller writes its own
;; terminator at the returned length; the size passed should leave room for it.
;; sys.executable and sys.prefix are the other caller.
;; ============================================================================
global exe_path
DEF_FUNC exe_path               ; + 0 pushes, 16-aligned at the call below
    mov rdx, rsi                ; size, before rdi is spent on the path
    mov rsi, rdi                ; buf
    CSTRING rdi, "/proc/self/exe"
    extern readlink
    call readlink
    test rax, rax
    jg .ep_out
    xor eax, eax                ; a failure reads as an empty path
.ep_out:
    leave
    ret
END_FUNC exe_path

;; ============================================================================
;; import_add_path_cstr(rdi = C string) -> nothing; appended to sys.path
;; ============================================================================
DEF_FUNC_LOCAL import_add_path_cstr
    call str_from_cstr_heap
    push rax
    sub rsp, 8
    mov rdi, [rel sys_path_list]
    mov rsi, rax
    call list_append
    add rsp, 8
    pop rdi
    call obj_decref
    leave
    ret
END_FUNC import_add_path_cstr

;; ============================================================================
DEF_FUNC import_init
    push rbx
    push r12
    mov rbx, rdi                ; argc
    mov r12, rsi                ; argv

    ; Where this interpreter's library is, before sys exists to report it.
    extern pathconfig_init
    call pathconfig_init

    ; Initialize sys module
    mov rdi, rbx
    mov rsi, r12
    call sys_module_init

    ; Register builtins module in sys.modules
    lea rdi, [rel im_builtins]
    call str_from_cstr_heap
    push rax                    ; key

    ; Create builtins module wrapping existing builtins dict
    lea rdi, [rel im_builtins]
    call str_from_cstr_heap
    push rax                    ; save name for DECREF
    mov rdi, rax
    mov rsi, [rel builtins_dict_global]
    call module_new
    mov rbx, rax                ; builtins module
    ; Kept, borrowed, because a module-level builtin's __self__ IS this module
    ; in CPython -- `len.__self__` is <module 'builtins'> there, and pickling
    ; a builtin by name goes through it.  sys.modules holds the reference.
    mov [rel builtins_module_obj], rax
    pop rdi                     ; DECREF name (module_new INCREF'd)
    call obj_decref

    ; dict_set(sys_modules, "builtins", builtins_module)
    mov rdi, [rel sys_modules_dict]
    pop rsi                     ; key = "builtins"
    push rsi                    ; re-save key for DECREF
    mov rdx, rbx
    call dict_set
    pop rdi                     ; DECREF key (dict_set INCREF'd)
    call obj_decref
    mov rdi, rbx                ; DECREF module (dict_set INCREF'd)
    call obj_decref

    ; Every remaining builtin module, from the one table
    ; sys.builtin_module_names is also built from.
    extern builtin_module_table
    xor r12d, r12d                          ; r12 = the row index
.ii_mod_loop:
    extern builtin_module_count
    cmp r12, [rel builtin_module_count]
    jge .ii_mods_done
    lea rax, [rel builtin_module_table]
    mov rcx, r12
    shl rcx, 4                              ; BuiltinModule_size
    mov rbx, [rax + rcx + BuiltinModule.create_fn]
    test rbx, rbx
    jz .ii_mod_next                         ; wired above, or by sys_module_init
    mov rdi, [rax + rcx + BuiltinModule.name]
    push r12                                ; r12 is the loop index and also
    push rdi                                ; the frame register; save it here
    call rbx
    mov rbx, rax                            ; the module, owned
    pop rdi
    call str_from_cstr_heap
    push rax                                ; the key
    push rax                                ; pushed twice to keep rsp aligned
    mov rdi, [rel sys_modules_dict]
    mov rsi, rax
    mov rdx, rbx
    call dict_set
    pop rdi
    pop rdi
    call obj_decref                         ; the key; dict_set took its own
    mov rdi, rbx
    call obj_decref                         ; the module, likewise
    pop r12
.ii_mod_next:
    inc r12
    jmp .ii_mod_loop
.ii_mods_done:

    ; PYTHONPATH, colon-separated, appended in order.
    ;
    ; CPython's own /usr/lib/python3.12 used to be appended here
    ; unconditionally, nominally "for re module access" -- which never
    ; worked, because apython cannot run that stdlib.  What it did do, once
    ; a failing module body stopped being swallowed, was turn "module not
    ; available" into "module half-imports and then raises from inside
    ; types.py".  A stdlib on the path has to be the caller's decision.
    ; Under -E or -I the environment is not consulted.
    extern main_sysflags
    cmp byte [rel main_sysflags + SF_IGNORE_ENV], 0
    jne .no_pythonpath
    CSTRING rdi, "PYTHONPATH"
    extern getenv
    call getenv
    test rax, rax
    jz .no_pythonpath
    mov r12, rax                ; cursor over the value
.pp_entry:
    cmp byte [r12], 0
    je .no_pythonpath
    ; measure up to ':' or NUL
    xor ecx, ecx
.pp_scan:
    movzx eax, byte [r12 + rcx]
    test al, al
    jz .pp_have_len
    cmp al, ':'
    je .pp_have_len
    inc rcx
    jmp .pp_scan
.pp_have_len:
    test rcx, rcx
    jz .pp_skip_sep             ; empty entry
    mov rdi, r12
    mov rsi, rcx
    push rcx
    call str_new_heap
    pop rcx
    push rax
    push rcx
    mov rdi, [rel sys_path_list]
    mov rsi, rax
    call list_append
    pop rcx
    pop rdi
    call obj_decref
.pp_skip_sep:
    add r12, rcx
    cmp byte [r12], 0
    je .no_pythonpath
    inc r12                     ; step over the ':'
    jmp .pp_entry
.no_pythonpath:

    ; The library apython ships, last, and found relative to the interpreter
    ; binary rather than the working directory -- a relative "lib" entry only
    ; resolved when apython happened to be run from its own source tree, so
    ; `import itertools` worked there and nowhere else.
    ;
    ; Two directories, in this order.  stdlib/ is CPython's own Lib/,
    ; unmodified; lib/ is what stands in for CPython's C modules (_io,
    ; _socket, _thread, ...).  The stand-ins come SECOND so that no name in
    ; lib/ can shadow a CPython module of the same name: a module that needs
    ; to differ from CPython's is a bug or a C module, and either way it does
    ; not belong ahead of the real one.
    ; Their locations come from pathconfig.asm, which knows the build tree
    ; from an installation.
    extern pc_stdlib, pc_dynload, pc_extra
    lea rdi, [rel pc_stdlib]
    call import_add_path_cstr
    lea rdi, [rel pc_dynload]
    call import_add_path_cstr
    cmp byte [rel pc_extra], 0
    je .ii_paths_done
    lea rdi, [rel pc_extra]
    call import_add_path_cstr
.ii_paths_done:

    pop r12
    pop rbx
    leave
    ret
END_FUNC import_init

;; ============================================================================
;; import_raise_no_module(rdi = name C string, rsi = name length,
;;                        rdx = parent length or 0) -- does not return
;;
;; Raises ModuleNotFoundError, matching CPython's two wordings:
;;
;;     No module named 'a.b'
;;     No module named 'a.b'; 'a' is not a package
;;
;; The name is given as a LENGTH into the full dotted string rather than as a
;; NUL-terminated one, because the prefix to blame is rarely the whole request:
;; `import sys.foo.bar` fails at `sys.foo`, and CPython names that.  The parent
;; is a second length into the same buffer, so neither needs a copy.
;; ============================================================================
IRNM_BUF equ 520                ; + 3 pushes = 544, 16-aligned
DEF_FUNC_LOCAL import_raise_no_module, IRNM_BUF
    push rbx
    push r12
    push r13
    mov rbx, rdi                ; the name buffer
    mov r12, rsi                ; the name length
    mov r13, rdx                ; the parent length, or 0
    lea rdi, [rbp - IRNM_BUF]
    xor ecx, ecx
    lea rdx, [rel im_no_module_prefix]
    call irnm_cat_cstr
    mov rdx, rbx
    mov rsi, r12
    call irnm_cat_n
    mov byte [rdi + rcx], 0x27  ; closing quote
    inc rcx
    test r13, r13
    jz .irnm_done
    lea rdx, [rel im_not_pkg_mid]
    call irnm_cat_cstr
    mov rdx, rbx
    mov rsi, r13
    call irnm_cat_n
    lea rdx, [rel im_not_pkg_tail]
    call irnm_cat_cstr
.irnm_done:
    mov byte [rdi + rcx], 0
    ; .name is the prefix that actually failed -- `import sys.foo.bar` reports
    ; 'sys.foo' -- so it is built from the same two values the message used.
    push rdi                    ; the message buffer, on this frame
    sub rsp, 8
    mov rdi, rbx
    mov rsi, r12
    call str_new_heap           ; 0 is tolerated: it becomes None
    add rsp, 8
    pop rsi                     ; the message
    mov rdx, rax                ; .name
    lea rdi, [rel exc_ModuleNotFoundError_type]
    xor ecx, ecx                ; .path is None
    mov r8d, 1                  ; the name string is ours to hand over
    call exc_raise_import
    ud2
END_FUNC import_raise_no_module

;; ============================================================================
;; irnm_cat_cstr(rdi = buffer, rcx = offset, rdx = NUL-terminated source)
;;     -> rcx advanced.  Clobbers rax and rdx only; rdi and every other
;;        register the caller is holding survive, because the caller keeps its
;;        buffer in rdi across a run of these.
;; ============================================================================
DEF_FUNC_BARE irnm_cat_cstr
.loop:
    movzx eax, byte [rdx]
    test al, al
    jz .done
    inc rdx
    cmp rcx, IRNM_BUF - 64      ; room for the longest remaining tail
    jae .done
    mov [rdi + rcx], al
    inc rcx
    jmp .loop
.done:
    ret
END_FUNC irnm_cat_cstr

;; ============================================================================
;; irnm_cat_n(rdi = buffer, rcx = offset, rdx = source, rsi = source length)
;;     -> rcx advanced.  Same contract as irnm_cat_cstr, for a counted string.
;; ============================================================================
DEF_FUNC_BARE irnm_cat_n
    xor eax, eax
.loop:
    cmp rax, rsi
    jae .done
    cmp rcx, IRNM_BUF - 64
    jae .done
    mov r8b, [rdx + rax]
    mov [rdi + rcx], r8b
    inc rax
    inc rcx
    jmp .loop
.done:
    ret
END_FUNC irnm_cat_n

;; ============================================================================
;; import_clear_attr_error() -> void
;;
;; A module's PEP 562 __getattr__ may raise AttributeError, and module_getattr
;; leaves that pending with attr_error_pending set so getattr()'s default and
;; hasattr() can still see it.  The import machinery asks modules for names it
;; expects to be missing -- `__path__` on a plain module, and the attribute
;; IMPORT_FROM is about before it tries a submodule of the same name -- and for
;; those a miss is an answer, not a failure.  CPython reads them with
;; _PyObject_LookupAttr, which swallows the AttributeError for the same reason.
;;
;; Only an AttributeError the hook raised is cleared: attr_error_pending says
;; so, and anything else pending is a real failure that must keep propagating.
;; ============================================================================
global import_clear_attr_error
DEF_FUNC import_clear_attr_error
    cmp qword [rel attr_error_pending], 0
    je .ica_done
    mov qword [rel attr_error_pending], 0
    mov qword [rel current_exception], 0
.ica_done:
    leave
    ret
END_FUNC import_clear_attr_error

;; ============================================================================
;; import_parent_is_package(rdi = whatever sys.modules holds for the parent)
;;     -> rax = 1 if a submodule of it may be imported, 0 if not
;;
;; CPython reads `parent.__path__` and turns an AttributeError into "'a' is not
;; a package".  A plain module without __path__ answers no, and so does the
;; None a blocker leaves behind -- which is why `import blocked.sub` reports
;; not-a-package rather than the halted message.
;;
;; Anything that is NOT a plain module answers YES, deliberately.  A module
;; subclass (the lazy-import trick) keeps its __path__ somewhere this cannot
;; see, and refusing it would break an import that works today; the cost is
;; that an exotic non-package object left in sys.modules keeps the older,
;; shorter message.  None is excluded from that leniency because a blocker is
;; the one case where the object is known not to be a package at all.
;; ============================================================================
IPP_FRAME equ 8                 ; + 1 push = 16, 16-aligned
DEF_FUNC_LOCAL import_parent_is_package, IPP_FRAME
    push rbx
    mov rbx, rdi
    test rbx, rbx
    jz .ipp_no
    V_TEST_PTR rbx, rax
    ja .ipp_yes                 ; an immediate is not a module; be lenient
    lea rax, [rel none_singleton]
    cmp rbx, rax
    je .ipp_no
    mov rax, [rbx + PyObject.ob_type]
    lea rcx, [rel module_type]
    cmp rax, rcx
    jne .ipp_yes
    mov rax, [rbx + PyModuleObject.mod_dict]
    test rax, rax
    jz .ipp_no

    ; the interned "__path__", built once and kept for the process
    mov rax, [rel im_path_key]
    test rax, rax
    jnz .ipp_have_key
    lea rdi, [rel im_dunder_path]
    call str_intern_cstr
    test rax, rax
    jz .ipp_yes                 ; out of memory: do not invent a refusal
    mov [rel im_path_key], rax
.ipp_have_key:
    mov rsi, rax
    mov rdi, [rbx + PyModuleObject.mod_dict]
    call dict_get               ; a Value; 0 is the miss
    test rax, rax
    jz .ipp_no
.ipp_yes:
    mov eax, 1
    pop rbx
    leave
    ret
.ipp_no:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC import_parent_is_package

;; ============================================================================
;; import_raise_halted(rdi = module name C string) -- does not return
;;
;; A None sitting in sys.modules is a deliberate BLOCK, not a cached module.
;; `test.support.import_fresh_module(m, blocked=[x])` puts one there and
;; expects the import of x to fail; we used to take the dict hit and hand the
;; None back, so `import x` bound None and raised nothing at all.
;;
;; CPython raises this from _bootstrap._find_and_load, right after the
;; sys.modules hit and before anything else, so it is checked for the name
;; actually being imported and only for that name -- `import a.b` with `a`
;; blocked is reported by the parent's own "is not a package" path instead.
;; The type is ModuleNotFoundError, an ImportError subclass.
;; ============================================================================
IRH_BUF equ 264                 ; + 1 push = 272, 16-aligned
DEF_FUNC_LOCAL import_raise_halted, IRH_BUF
    push rbx
    mov rbx, rdi                ; the name, kept across the message build
    mov rsi, rdi                ; the name
    lea rdi, [rbp - IRH_BUF]
    xor ecx, ecx
    lea rdx, [rel im_halted_prefix]
.irh_prefix:
    movzx eax, byte [rdx]
    test al, al
    jz .irh_name
    inc rdx
    mov [rdi + rcx], al
    inc rcx
    jmp .irh_prefix
.irh_name:
    movzx eax, byte [rsi]
    test al, al
    jz .irh_suffix
    inc rsi
    cmp rcx, IRH_BUF - 40       ; room for the whole suffix and the NUL
    jae .irh_suffix
    mov [rdi + rcx], al
    inc rcx
    jmp .irh_name
.irh_suffix:
    lea rdx, [rel im_halted_suffix]
.irh_suffix_loop:
    movzx eax, byte [rdx]
    test al, al
    jz .irh_done
    inc rdx
    mov [rdi + rcx], al
    inc rcx
    jmp .irh_suffix_loop
.irh_done:
    mov byte [rdi + rcx], 0
    ; CPython sets .name to the module that was blocked, and leaves .path None.
    ; The string is built only for this, and exc_raise_import does not return,
    ; so it is handed over to be released there.
    push rdi                    ; the message buffer, on this frame
    sub rsp, 8
    mov rdi, rbx
    call str_from_cstr_heap     ; 0 is tolerated: it becomes None
    add rsp, 8
    pop rsi                     ; the message
    mov rdx, rax                ; .name
    lea rdi, [rel exc_ModuleNotFoundError_type]
    xor ecx, ecx                ; .path is None
    mov r8d, 1                  ; the name string is ours to hand over
    call exc_raise_import
    ud2
END_FUNC import_raise_halted

;; ============================================================================
;; import_module(PyObject *name_str, PyObject *fromlist, int64_t level) -> PyObject*
;; Main import entry point
;; name_str = module name from co_names
;; fromlist = tuple of names or None
;; level = 0 for absolute, >0 for relative
;; Returns: module object (new reference)
;; ============================================================================
DEF_FUNC import_module, IF_FRAME
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov [rbp - IF_NAME], rdi        ; name_str
    mov [rbp - IF_FROMLIST], rsi    ; fromlist
    mov [rbp - IF_LEVEL], rdx       ; level
    DUNDER_EXC_SAVE [rbp - IF_EXC]  ; see .import_error

    ; Get name as C string for comparisons
    mov rdi, [rbp - IF_NAME]
    lea rbx, [rdi + PyStrObject.data]  ; rbx = name cstr
    mov r14, [rdi + PyStrObject.ob_size] ; r14 = name length
    mov [rbp - IF_FAILLEN], r14     ; blame the whole name unless a walk
    mov qword [rbp - IF_FAILPAR], 0 ; narrows it to a failing prefix

    ; Check sys.modules first
    mov rdi, [rel sys_modules_dict]
    mov rsi, [rbp - IF_NAME]
    call dict_get
    V_UNPACK rax, rdx           ; dict_get returns a Value
    test edx, edx
    jnz .found_cached

    ; For dotted names (a.b.c), import each component
    ; First, check if name contains a dot
    xor ecx, ecx
.find_dot:
    cmp rcx, r14
    jge .no_dot
    cmp byte [rbx + rcx], '.'
    je .has_dots
    inc rcx
    jmp .find_dot

.no_dot:
    ; Simple name, no dots
    mov rdi, [rbp - IF_NAME]
    call import_find_and_load
    test rax, rax
    jz .import_error
    mov r12, rax                ; r12 = module

    ; If fromlist is empty/None, return this module
    ; If fromlist is non-empty, return this module (it's already the leaf)
    mov rax, r12
    jmp .done

.has_dots:
    ; Dotted name: import each prefix in turn, `a`, then `a.b`, then `a.b.c`,
    ; binding each as an attribute of the one before.  Importing only the
    ; first component and then the whole name skipped the intermediate
    ; packages entirely, so anything three deep -- `import a.b.c` -- reported
    ; ModuleNotFoundError, and the submodule was hung off the *top* package
    ; rather than its own parent.
    mov qword [rbp - IF_POS], 0
    mov qword [rbp - IF_PARENT], 0
    mov qword [rbp - IF_LEAF], 0
    mov qword [rbp - IF_TOPMOD], 0

.walk_component:
    ; The prefix ends at the next dot, or at the end of the name.
    mov rcx, [rbp - IF_POS]
.walk_scan:
    cmp rcx, r14
    jae .walk_have_end
    cmp byte [rbx + rcx], '.'
    je .walk_have_end
    inc rcx
    jmp .walk_scan
.walk_have_end:
    push rcx                    ; where this component ends
    mov rdi, rbx
    mov rsi, rcx
    call str_new_heap           ; the prefix, "a" then "a.b" then "a.b.c"
    test rax, rax
    jz .walk_oom
    push rax

    mov rdi, [rel sys_modules_dict]
    mov rsi, rax
    call dict_get
    test rax, rax               ; dict_get answers with a Value; 0 is the miss
    jnz .walk_have_module

    ; A parent that is not a package cannot have submodules -- but ONLY ask
    ; that once the child's own sys.modules entry has missed, which is
    ; CPython's order in _find_and_load_unlocked:
    ;
    ;     if parent not in sys.modules: import_(parent)
    ;     # Crazy side-effects!
    ;     if name in sys.modules: return sys.modules[name]
    ;     parent_module = sys.modules[parent]
    ;     try: path = parent_module.__path__
    ;     except AttributeError: ... 'x' is not a package
    ;
    ; A package may install its own submodule there, and `os` is exactly that
    ; arrangement: it is NOT a package, and lib/os.py ends with
    ; `sys.modules['os.path'] = path`.  Asking about `os.__path__` first made
    ; `import os.path` a ModuleNotFoundError.
    ;
    ; The check still has to come before import_find_and_load, which falls
    ; back to sys.path when the parent has no __path__ to search -- so with a
    ; top-level foo.py importable, `import sys.foo` SUCCEEDED and bound it as
    ; sys.foo.  Between the two lookups is the only place both are true.
    mov rax, [rbp - IF_PARENT]
    test rax, rax
    jz .walk_load
    mov rdi, rax
    call import_parent_is_package
    test eax, eax
    jnz .walk_load
    mov rcx, [rsp + 8]              ; where this component ends
    mov [rbp - IF_FAILLEN], rcx     ; the child, `sys.foo`
    mov rax, [rbp - IF_POS]
    dec rax                         ; less the dot: the parent, `sys`
    mov [rbp - IF_FAILPAR], rax
    mov rdi, [rsp]
    call obj_decref                 ; the prefix string; the stack itself is
    jmp .import_error               ; restored by the epilogue's `leave`

.walk_load:
    mov rdi, [rsp]
    call import_find_and_load
    test rax, rax
    jz .walk_load_failed

.walk_have_module:
    mov r13, rax                ; this prefix's module, borrowed
    pop rdi                     ; the prefix string
    call obj_decref
    pop rcx                     ; where the component ended

    ; Bind it on its parent under the bare component name.
    mov rax, [rbp - IF_PARENT]
    test rax, rax
    jz .walk_no_parent
    push rcx
    push r13
    mov rdi, [rbp - IF_POS]
    lea rdi, [rbx + rdi]        ; the bare component
    mov rsi, rcx
    sub rsi, [rbp - IF_POS]
    call str_new_heap
    test rax, rax
    jz .walk_no_parent_pop
    push rax
    mov rax, [rbp - IF_PARENT]
    mov rdi, [rax + PyModuleObject.mod_dict]
    test rdi, rdi
    jz .walk_drop_key
    mov rsi, [rsp]
    mov rdx, [rsp + 8]          ; this prefix's module
    call dict_set
.walk_drop_key:
    pop rdi
    call obj_decref
.walk_no_parent_pop:
    pop r13
    pop rcx
.walk_no_parent:

    mov [rbp - IF_PARENT], r13
    mov [rbp - IF_LEAF], r13
    cmp qword [rbp - IF_TOPMOD], 0
    jne .walk_have_top
    mov [rbp - IF_TOPMOD], r13
.walk_have_top:

    cmp rcx, r14
    jae .walk_done
    lea rcx, [rcx + 1]          ; step past the dot
    mov [rbp - IF_POS], rcx
    jmp .walk_component

.walk_done:
    mov r12, [rbp - IF_TOPMOD]
    inc qword [r12 + PyObject.ob_refcnt]
    mov r13, [rbp - IF_LEAF]

.skip_set_parent:
    ; Decide what to return based on fromlist
    mov rax, [rbp - IF_FROMLIST]
    ; Check if fromlist is None (inline TAG_NONE has payload=0, pointer form has none_singleton)
    test rax, rax
    jz .return_top
    lea rcx, [rel none_singleton]
    cmp rax, rcx
    je .return_top
    ; Check tuple size (fromlist is always None or tuple)
    mov rcx, [rax + PyTupleObject.ob_size]
    test rcx, rcx
    jz .return_top
    ; Check tuple size
    mov rcx, [rax + PyTupleObject.ob_size]
    test rcx, rcx
    jz .return_top

    ; fromlist is non-empty -> return leaf module
    mov rax, r13
    inc qword [rax + PyObject.ob_refcnt]
    ; DECREF top module
    mov rdi, r12
    call obj_decref
    jmp .done

.return_top:
    ; fromlist empty -> return top-level module
    mov rax, r12
    ; r12 already INCREF'd above
    jmp .done

.walk_load_failed:
    pop rdi                     ; the prefix string
    call obj_decref
    pop rcx                     ; where the component ended
    mov [rbp - IF_FAILLEN], rcx ; `import sys.foo.bar` fails at `sys.foo`
    jmp .import_error

.walk_oom:
    pop rcx
    jmp .import_error

.found_cached:
    ; A None here is a BLOCK, not a module -- see import_raise_halted.  It has
    ; to be tested before the want-top rewrite below, which would otherwise
    ; read PyStrObject fields off the None while looking for the first
    ; component.
    lea rcx, [rel none_singleton]
    cmp rax, rcx
    je .cached_blocked

    ; Found in sys.modules.  With an empty fromlist a dotted import still
    ; evaluates to the *top* package -- `import a.b` binds `a` -- so a cache
    ; hit on the full name has to hand back the first component instead, or
    ; the IMPORT_FROM walk that follows is applied to the wrong module.
    mov rdx, [rbp - IF_FROMLIST]
    test rdx, rdx
    jz .cached_want_top
    lea rcx, [rel none_singleton]
    cmp rdx, rcx
    je .cached_want_top
    cmp qword [rdx + PyTupleObject.ob_size], 0
    jne .cached_as_is
.cached_want_top:
    ; Only when the name is dotted; otherwise it already is the top.
    xor ecx, ecx
.cached_find_dot:
    cmp rcx, r14
    jae .cached_as_is
    cmp byte [rbx + rcx], '.'
    je .cached_dotted
    inc rcx
    jmp .cached_find_dot
.cached_dotted:
    push rax
    mov rdi, rbx
    mov rsi, rcx
    call str_new_heap
    test rax, rax
    jz .cached_pop_as_is
    push rax
    mov rdi, [rel sys_modules_dict]
    mov rsi, rax
    call dict_get
    V_UNPACK rax, rdx
    mov rcx, rax
    pop rdi
    push rcx
    call obj_decref             ; the prefix string
    pop rcx
    pop rax
    test rcx, rcx
    jz .cached_as_is            ; not cached after all; the full one will do
    mov rax, rcx
    jmp .cached_as_is
.cached_blocked:
    mov rdi, rbx                ; the name C string, still live from the entry
    call import_raise_halted
    ud2

.cached_pop_as_is:
    pop rax
.cached_as_is:
    inc qword [rax + PyObject.ob_refcnt]
    jmp .done

.import_error:
    ; If the module was found and its body raised, that exception is the
    ; error; raising ImportError over it would replace the real cause with
    ; a generic "no module named X".
    ;
    ; Compared against the value saved on entry, not against 0:
    ; current_exception is also the exception *being handled*, so inside
    ; `except ImportError:` -- which is how the whole stdlib probes for its
    ; optional C accelerators -- a bare test sees the handled exception and
    ; re-propagates it in place of the real one.
    DUNDER_RAISED [rbp - IF_EXC], .propagate_pending

    ; ModuleNotFoundError, not a bare ImportError: it is an ImportError
    ; subclass and stdlib code catches it specifically.  CPython's wording
    ; is "No module named 'x'".
    mov rdi, rbx                ; the dotted name buffer
    mov rsi, [rbp - IF_FAILLEN] ; the prefix that actually failed
    mov rdx, [rbp - IF_FAILPAR] ; and its parent, when that is the reason
    call import_raise_no_module
    ; does not return

.propagate_pending:
    jmp eval_exception_unwind

.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC import_module


;; ============================================================================
;; import_submodule_attr(rdi = a package module, rsi = an attribute name str)
;;   -> rax = the submodule, BORROWED (sys.modules owns it), or 0
;;
;; `from pkg import sub` and `from pkg import *` both have to IMPORT a
;; submodule that the package's own body never bound.  CPython does it in
;; _handle_fromlist, once, for both; the two paths here had drifted apart --
;; IMPORT_FROM did it and IMPORT_STAR did not, so an __all__ naming a
;; submodule raised AttributeError instead of importing it.
;;
;; The submodule is also bound on the package under its bare name, which is
;; what makes `from . import x` inside one submodule leave `x` visible in the
;; package itself: a package's __init__ shares its globals with the module
;; object, so CPython's setattr on the parent is the whole mechanism.
;; ============================================================================
ISA_MOD  equ 8
ISA_ATTR equ 16
ISA_T1   equ 24
ISA_T2   equ 32
ISA_FRAME equ 48            ; + 0 pushes = 48, 16-aligned
global import_submodule_attr
DEF_FUNC import_submodule_attr, ISA_FRAME
    mov [rbp - ISA_MOD], rdi
    mov [rbp - ISA_ATTR], rsi

    ; With importlib installed, lib/_importlib_bootstrap.py answers, CPython's
    ; way: sys.modules first, an import only for a package, and only a
    ; ModuleNotFoundError for exactly that submodule taken as "absent".
    CSTRING rdi, "_import_submodule"
    call im_importlib_func
    test rax, rax
    jz .isa_own
    ; (module, name) as an argument array: ISA_T2 is the lower address.
    mov rcx, [rbp - ISA_MOD]
    mov [rbp - ISA_T2], rcx
    mov rcx, [rbp - ISA_ATTR]
    mov [rbp - ISA_T1], rcx
    mov rdi, rax
    lea rsi, [rbp - ISA_T2]
    mov edx, 2
    call obj_call_n
    test rax, rax
    jz .isa_out_raw                ; it raised: 0 with the exception pending
    lea rcx, [rel none_singleton]
    cmp rax, rcx
    je .isa_absent
    ; sys.modules holds the module; the caller takes a borrowed reference.
    mov [rbp - ISA_T2], rax
    mov rdi, rax
    call obj_decref
    mov rax, [rbp - ISA_T2]
    leave
    ret
.isa_absent:
    mov rdi, rax
    call obj_decref
    xor eax, eax
.isa_out_raw:
    leave
    ret
.isa_own:
    mov rdi, [rbp - ISA_MOD]
    mov rsi, [rbp - ISA_ATTR]
    ; Only a module has a mod_dict.  sys.modules is an ordinary dict and a
    ; program may put anything in it -- importlib's own import_fresh_module
    ; does -- so this used to read a field belonging to some other struct and
    ; hand it to dict_get.
    extern import_module_dict
    call import_module_dict
    mov rdi, rax
    test rdi, rdi
    jz .isa_none

    ; The package's own __name__, which the dotted name is built from.
    lea rdi, [rel isa_dunder_name]
    call str_from_cstr_heap
    test rax, rax
    jz .isa_none
    mov [rbp - ISA_T1], rax
    mov rdi, [rbp - ISA_MOD]
    call import_module_dict
    mov rdi, rax
    mov rsi, [rbp - ISA_T1]
    call dict_get
    V_UNPACK rax, rdx
    mov [rbp - ISA_T2], rax
    mov rdi, [rbp - ISA_T1]
    call obj_decref
    cmp qword [rbp - ISA_T2], 0
    je .isa_none

    ; "pkg" + "." + "attr"
    lea rdi, [rel isa_dot]
    call str_from_cstr_heap
    test rax, rax
    jz .isa_none
    mov [rbp - ISA_T1], rax
    mov rdi, [rbp - ISA_T2]
    mov rsi, rax
    mov ecx, TAG_PTR
    call str_concat
    mov [rbp - ISA_T2], rax
    mov rdi, [rbp - ISA_T1]
    call obj_decref
    cmp qword [rbp - ISA_T2], 0
    je .isa_none

    mov rdi, [rbp - ISA_T2]
    mov rsi, [rbp - ISA_ATTR]
    mov ecx, TAG_PTR
    call str_concat
    mov [rbp - ISA_T1], rax
    mov rdi, [rbp - ISA_T2]
    call obj_decref
    cmp qword [rbp - ISA_T1], 0
    je .isa_none

    mov rdi, [rbp - ISA_T1]
    call import_find_and_load
    mov [rbp - ISA_T2], rax
    mov rdi, [rbp - ISA_T1]
    call obj_decref
    cmp qword [rbp - ISA_T2], 0
    je .isa_none

    mov rdi, [rbp - ISA_MOD]
    mov rdi, [rdi + PyModuleObject.mod_dict]
    test rdi, rdi
    jz .isa_out
    mov rsi, [rbp - ISA_ATTR]
    mov rdx, [rbp - ISA_T2]
    call dict_set
.isa_out:
    mov rax, [rbp - ISA_T2]
    leave
    ret
.isa_none:
    xor eax, eax
    leave
    ret
END_FUNC import_submodule_attr

section .rodata
isa_dunder_name: db "__name__", 0
isa_dot:         db ".", 0
section .text

;; ============================================================================
;; ifl_get(rdi = a dict, rsi = C string key) -> rax = the Value, BORROWED, or 0
;; ============================================================================
IFG_DICT  equ 8
IFG_KEY   equ 16
IFG_VAL   equ 24
IFG_FRAME equ 32
DEF_FUNC_LOCAL ifl_get, IFG_FRAME
    mov [rbp - IFG_DICT], rdi
    mov rdi, rsi
    call str_from_cstr_heap
    mov [rbp - IFG_KEY], rax
    mov rdi, [rbp - IFG_DICT]
    mov rsi, rax
    call dict_get
    mov [rbp - IFG_VAL], rax
    mov rdi, [rbp - IFG_KEY]
    call obj_decref
    mov rax, [rbp - IFG_VAL]
    leave
    ret
END_FUNC ifl_get

;; ============================================================================
;; im_importlib_func(rdi = C string) -> rax = that function of
;;   lib/_importlib_bootstrap.py, BORROWED, or 0 while it is not loaded yet
;;
;; Looked up each time rather than cached: a process-lifetime pointer to a
;; module attribute dangles when the module is dropped from sys.modules.
;; ============================================================================
IIF_NAME  equ 8
IIF_FRAME equ 16
DEF_FUNC_LOCAL im_importlib_func, IIF_FRAME
    mov [rbp - IIF_NAME], rdi
    mov rdi, [rel sys_modules_dict]
    CSTRING rsi, "_importlib_bootstrap"
    call ifl_get
    test rax, rax
    jz .iif_none
    V_TEST_PTR rax, rcx
    ja .iif_none
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel module_type]
    cmp rcx, rdx
    jne .iif_none
    mov rdi, [rax + PyModuleObject.mod_dict]
    test rdi, rdi
    jz .iif_none
    mov rsi, [rbp - IIF_NAME]
    call ifl_get
    leave
    ret
.iif_none:
    xor eax, eax
    leave
    ret
END_FUNC im_importlib_func

;; ============================================================================
;; import_find_and_load(PyObject *name_str) -> PyObject*, a new reference,
;;   or NULL with the exception pending
;;
;; What the import statement does on a sys.modules miss: CPython's
;; _bootstrap._find_and_load, reached through lib/_importlib_bootstrap.py --
;; meta_path, path hooks, specs, loaders, all CPython's own code.  Until that
;; module has finished loading there is no importlib to ask, and the
;; interpreter's own loader below does the job; it is how importlib itself
;; gets loaded, and what _impcore.create_builtin uses for a builtin.
;; ============================================================================
IFL_NAME  equ 8
IFL_ARG   equ 16
IFL_FRAME equ 16
DEF_FUNC import_find_and_load, IFL_FRAME
    mov [rbp - IFL_NAME], rdi
    CSTRING rdi, "_find_and_load"
    call im_importlib_func
    test rax, rax
    jz .ifl_own
    mov rcx, [rbp - IFL_NAME]
    mov [rbp - IFL_ARG], rcx
    mov rdi, rax
    lea rsi, [rbp - IFL_ARG]
    mov edx, 1
    call obj_call_n
    leave
    ret
.ifl_own:
    mov rdi, [rbp - IFL_NAME]
    call import_find_and_load_asm
    leave
    ret
END_FUNC import_find_and_load

;; ============================================================================
;; import_find_and_load_asm(PyObject *name_str) -> PyObject*
;; Find module on disk and load it, without importlib.
;; For dotted names (e.g. "unittest.case"), searches parent package's __path__.
;; Returns module object or NULL.
;; ============================================================================
global import_find_and_load_asm
DEF_FUNC import_find_and_load_asm, FL_FRAME
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov [rbp - FL_NAME], rdi    ; save name_str

    ; Check sys.modules first — avoid re-loading already-imported modules
    mov rdi, [rel sys_modules_dict]
    mov rsi, [rbp - FL_NAME]
    call dict_get
    test rax, rax               ; dict_get answers with a Value; 0 is the miss
    jnz .found_in_sysmod

    ; Ensure path buffer is allocated
    mov rdi, [rel import_path_buf_ptr]
    test rdi, rdi
    jnz .have_buf
    mov edi, PATHBUF_SIZE
    call ap_malloc
    mov [rel import_path_buf_ptr], rax
.have_buf:

    ; Compute leaf name: last component after final '.'
    ; e.g. "unittest.case" -> leaf="case", "unittest" -> leaf="unittest"
    mov rbx, [rbp - FL_NAME]
    lea r14, [rbx + PyStrObject.data]  ; full name cstr
    mov r15, [rbx + PyStrObject.ob_size] ; full name length

    ; Find last '.' to get leaf name
    mov rcx, r15
.find_last_dot:
    dec rcx
    js .no_dot_found
    cmp byte [r14 + rcx], '.'
    jne .find_last_dot
    ; Found dot at position rcx; leaf starts at rcx+1
    lea rax, [r14 + rcx + 1]
    mov [rbp - FL_LEAF], rax
    mov rax, r15
    sub rax, rcx
    dec rax                     ; leaf length
    mov [rbp - FL_LEAFLEN], rax
    jmp .have_leaf

.no_dot_found:
    ; No dot: leaf = full name
    mov [rbp - FL_LEAF], r14
    mov [rbp - FL_LEAFLEN], r15

.have_leaf:
    ; For dotted names, try parent package's __path__ first
    ; Find last '.' position again to extract parent name
    mov rcx, r15
.find_parent_dot:
    dec rcx
    js .search_sys_path         ; no dot -> top-level, search sys.path
    cmp byte [r14 + rcx], '.'
    jne .find_parent_dot

    ; Dotted name: parent = name[0..rcx]
    ; Create parent name string and look up in sys.modules
    lea rdi, [r14]              ; parent name cstr
    mov rsi, rcx                ; parent name length
    call str_new_heap
    mov r12, rax                ; r12 = parent name str

    ; Look up parent in sys.modules
    mov rdi, [rel sys_modules_dict]
    mov rsi, r12
    call dict_get
    V_UNPACK rax, rdx           ; dict_get returns a Value
    mov r13, rax                ; r13 = parent module payload (or 0)
    push rdx                    ; save dict_get tag for found check

    ; DECREF parent name str
    mov rdi, r12
    call obj_decref

    ; If parent not found, fall through to sys.path search
    pop rdx                     ; restore dict_get tag
    test edx, edx
    jz .search_sys_path

    ; Get parent's __path__ attribute (from module dict)
    ; Module dict is at module.ob_dict (PyModuleObject.ob_dict)
    mov rax, [r13 + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_getattr]
    test rax, rax
    jz .search_sys_path

    ; getattr(parent_module, "__path__")
    ; Save tp_getattr (caller-saved regs clobbered by str_from_cstr)
    push rax                    ; save tp_getattr
    push r13                    ; save parent module
    lea rdi, [rel im_dunder_path]
    call str_from_cstr_heap
    pop r13                     ; restore parent module
    pop rcx                     ; restore tp_getattr
    push rax                    ; save "__path__" str
    mov rdi, r13                ; parent module
    mov rsi, rax                ; "__path__" key
    call rcx                    ; tp_getattr
    mov r12, rax                ; r12 = __path__ list (or NULL)
    pop rdi                     ; DECREF "__path__" str
    call obj_decref

    test r12, r12
    jnz .have_parent_path
    ; A plain module has no __path__, and under PEP 562 its own __getattr__ may
    ; have said so by raising; that is an answer here, not a failure.
    call import_clear_attr_error
    jmp .search_sys_path
.have_parent_path:

    ; r12 = parent's __path__ (a list). Search it for the leaf module.
    mov rdi, r12                ; search_list = __path__
    mov rsi, [rbp - FL_LEAF]    ; leaf cstr
    mov rdx, [rbp - FL_LEAFLEN] ; leaf len
    call import_search_dirs
    ; DECREF __path__ (getattr returned new ref)
    push rax                    ; save result
    mov rdi, r12
    call obj_decref
    pop rax

    test rax, rax
    jnz .found_result           ; found it in parent's __path__
    ; Fall through to sys.path

.search_sys_path:
    ; Build full path component: name with dots replaced by slashes
    ; Stack buffer for path component
    sub rsp, FL_STKSZ
    mov r12, rsp                ; r12 = path_component buffer

    ; Copy name, replacing '.' with '/'
    mov rbx, [rbp - FL_NAME]
    lea r14, [rbx + PyStrObject.data]
    mov r15, [rbx + PyStrObject.ob_size]
    xor ecx, ecx
.copy_name:
    cmp rcx, r15
    jge .copy_done
    movzx eax, byte [r14 + rcx]
    cmp al, '.'
    jne .no_replace
    mov al, '/'
.no_replace:
    mov [r12 + rcx], al
    inc rcx
    jmp .copy_name
.copy_done:
    mov byte [r12 + rcx], 0    ; null-terminate

    ; Search sys.path -- or, for _impcore.create_builtin, only the directory
    ; the stand-ins for C modules live in: a builtin does not depend on what
    ; a program has done to sys.path, as CPython's are compiled in.
    mov rdi, [rel import_path_override]
    test rdi, rdi
    jnz .have_search_list
    mov rdi, [rel sys_path_list]
.have_search_list:
    mov rsi, [rbp - FL_LEAF]
    mov rdx, [rbp - FL_LEAFLEN]
    mov rcx, r12                ; full path component (with slashes)
    call import_search_syspath
    add rsp, FL_STKSZ

    test rax, rax
    jnz .found_result

    ; Not found anywhere
    xor eax, eax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.found_in_sysmod:
    ; A None here is a BLOCK, not a module; see import_raise_halted.
    lea rcx, [rel none_singleton]
    cmp rax, rcx
    jne .fis_real
    mov rdi, [rbp - FL_NAME]
    lea rdi, [rdi + PyStrObject.data]
    call import_raise_halted
    ud2
.fis_real:
    ; Already imported — return INCREF'd reference
    inc qword [rax + PyObject.ob_refcnt]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.found_result:
    ; rax = 1 (package), 2 (module) or 3 (a PEP 420 namespace package, which
    ; has no file to load); path is in import_path_buf_ptr
    mov r12d, eax               ; save type
    cmp r12d, 3
    je .load_as_namespace
    mov rdi, [rbp - FL_NAME]
    mov rsi, [rel import_path_buf_ptr]
    xor edx, edx
    cmp r12d, 1
    jne .load_as_module
    mov edx, 1                  ; is_package = 1
.load_as_module:
    call import_load_module

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.load_as_namespace:
    mov rdi, [rbp - FL_NAME]
    call import_make_namespace

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC import_find_and_load_asm

;; ============================================================================
;; sd_pyc_ok(rdi = an open fd on a .pyc, rsi = its path) -> rax = the fd when
;;   the .pyc may be used, eax = 0 when it may not.  Closes the fd and returns
;;   0 for a .pyc whose source has been edited since it was written, so the
;;   search falls through to the next pattern and, in the end, to the source.
;; ============================================================================
SPO_FD    equ 8
SPO_FRAME equ 16            ; + 0 pushes = 16
DEF_FUNC_LOCAL sd_pyc_ok, SPO_FRAME
    mov [rbp - SPO_FD], rdi
    call pyc_is_stale
    test eax, eax
    jnz .spo_stale
    mov rax, [rbp - SPO_FD]
    leave
    ret
.spo_stale:
    mov rdi, [rbp - SPO_FD]
    call sys_close
    xor eax, eax
    leave
    ret
END_FUNC sd_pyc_ok

;; ============================================================================
;; pyc_is_stale(rdi = an OPEN fd on the .pyc, rsi = its path) -> eax = 1 when
;;   the source beside it has been edited since it was written
;;
;; A .pyc records the source's mtime and size in its header, and CPython
;; refuses one whose source no longer matches -- otherwise editing a module
;; and running it again silently runs the old code, which is what happened
;; here.  The check only applies to the timestamp form: a hash-based .pyc
;; (flags bit 0) records a hash instead, and an unchecked one is meant to be
;; taken on trust.  A .pyc with no source beside it is CPython's sourceless
;; form and is always fresh.
;;
;; The fd is left where it was: this reads the header and seeks back.
;; ============================================================================
PIS_FD    equ 8
PIS_HDR   equ 24            ; the 16-byte header
PIS_STAT  equ 24 + 144      ; STAT_SIZE
PIS_FRAME equ ((PIS_STAT + 15) / 16) * 16 + 8   ; + 1 push = 16-aligned
DEF_FUNC_LOCAL pyc_is_stale, PIS_FRAME
    push rbx
    mov [rbp - PIS_FD], rdi
    mov rbx, rsi

    ; The source it was built from, if the name says there is one.
    mov rdi, rbx
    call import_source_path
    cmp rax, rbx
    je .pis_fresh               ; sourceless: nothing to compare against
    mov rdi, rax
    lea rsi, [rbp - PIS_STAT]
    call sys_stat
    test rax, rax
    js .pis_fresh               ; the source is gone; the .pyc stands alone

    ; The header: magic, flags, mtime, size.
    mov rdi, [rbp - PIS_FD]
    lea rsi, [rbp - PIS_HDR]
    mov edx, 16
    call sys_read
    push rax
    mov rdi, [rbp - PIS_FD]
    xor esi, esi
    xor edx, edx
    extern sys_lseek
    call sys_lseek              ; back to the start, for the real reader
    pop rax
    cmp rax, 16
    jne .pis_fresh

    mov eax, [rbp - PIS_HDR + 4]
    test eax, 1
    jnz .pis_fresh              ; hash-based: not a timestamp to compare

    mov eax, [rbp - PIS_HDR + 8]        ; the source mtime it recorded
    mov ecx, [rbp - PIS_STAT + 88]      ; st_mtime, low 32 bits
    cmp eax, ecx
    jne .pis_stale
    mov eax, [rbp - PIS_HDR + 12]       ; and its size
    mov ecx, [rbp - PIS_STAT + 48]      ; st_size, low 32 bits
    cmp eax, ecx
    jne .pis_stale
.pis_fresh:
    xor eax, eax
    pop rbx
    leave
    ret
.pis_stale:
    mov eax, 1
    pop rbx
    leave
    ret
END_FUNC pyc_is_stale

;; ============================================================================
;; import_source_path(rdi = the path a search matched) -> rax = the path to
;;   record as __file__, which is rdi itself unless it is a __pycache__ entry
;;
;; "<dir>/__pycache__/<name>.<tag>.pyc" becomes "<dir>/<name>.py", for either
;; of the two cache tags im_open_pyc reads.  The
;; other two cache shapes the search tries -- a bare "<name>.cpython-312.pyc"
;; beside the source, and a package's __init__ -- are handled by the same
;; rewrite, since both keep the name in the last component.  A .pyc that is
;; NOT in a __pycache__ directory is CPython's sourceless form, whose
;; __file__ is the .pyc, so it is left alone.
;;
;; The answer is written into a buffer of its own: the caller's path is the
;; one the code object was loaded from and is still needed.
;; ============================================================================
global import_source_path
DEF_FUNC import_source_path
    push rbx
    push r12
    push r13
    push r14                    ; four pushes keep rsp 16-aligned at the call
    mov rbx, rdi

    ; It has to end in one of the two cache tags.
    mov rdi, rbx
    call ap_strlen
    mov r12, rax                ; the length
    cmp r12, 16 + 13            ; the suffix, plus the shortest marker
    jb .isp_keep
    ; ap_memcmp with an explicit length, not ap_strcmp: that one compares
    ; eight bytes at a time and reads past the terminator, and the path here
    ; sits in a heap buffer whose tail was never written.  Valgrind says so.
    lea rdi, [rbx + r12 - 16]
    lea rsi, [rel isp_suffix]
    mov edx, 16
    call ap_memcmp
    test eax, eax
    jz .isp_tagged
    lea rdi, [rbx + r12 - 16]
    lea rsi, [rel isp_ap_suffix]
    mov edx, 16
    call ap_memcmp
    test eax, eax
    jnz .isp_keep
.isp_tagged:

    ; ...and contain "/__pycache__/" somewhere before the last component.
    xor r13, r13                ; the index of the marker, once found
    mov r14, -1
.isp_scan:
    lea rax, [r13 + 13]
    cmp rax, r12
    ja .isp_scanned
    push r13
    lea rdi, [rbx + r13]
    lea rsi, [rel isp_marker]
    mov edx, 13
    call ap_memcmp
    pop r13
    test eax, eax
    jnz .isp_scan_next
    mov r14, r13
.isp_scan_next:
    inc r13
    jmp .isp_scan
.isp_scanned:
    cmp r14, -1
    je .isp_keep

    ; <dir> is everything before the marker; <name> is between the marker's
    ; trailing slash and the suffix.
    lea rax, [r14 + 13]         ; the first byte of <name>
    lea rcx, [r12 - 16]         ; one past its last
    cmp rcx, rax
    jbe .isp_keep
    sub rcx, rax                ; the name's length
    lea rdx, [r14 + rcx + 4]    ; <dir> + '/' + <name> + ".py" + NUL
    cmp rdx, ISP_BUFSZ
    jae .isp_keep

    lea rdi, [rel isp_buf]
    mov rsi, rbx
    mov rdx, r14
    push rcx
    push rax
    call ap_memcpy              ; <dir>, without the trailing slash
    pop rax
    pop rcx
    lea rdi, [rel isp_buf]
    add rdi, r14
    mov byte [rdi], '/'
    inc rdi
    lea rsi, [rbx + rax]
    mov rdx, rcx
    push rcx
    call ap_memcpy
    pop rcx
    lea rdi, [rel isp_buf]
    add rdi, r14
    add rdi, rcx
    inc rdi
    mov dword [rdi], `.py\0`
    lea rax, [rel isp_buf]
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.isp_keep:
    mov rax, rbx
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC import_source_path

;; ============================================================================
;; im_open_pyc(rdi = a path ending in a sixteen-byte cache tag, rsi = its
;;   length) -> rax = an open fd on a FRESH .pyc, or -1
;;
;; Two spellings are tried, in order: ".apython-312.pyc" and
;; ".cpython-312.pyc".  They are the same sixteen characters long, so the
;; second is the first with the tag overwritten in place.
;;
;; The two tags exist because this interpreter both READS CPython's caches --
;; `make check` feeds it .pyc files python3 compiled, and it must -- and now
;; WRITES its own.  Writing under CPython's tag would put bytecode from this
;; compiler where a python3 running in the same tree would pick it up: valid
;; 3.12 bytecode, but not the bytecode CPython would have produced, and the
;; sweeps in tests/ measure apython against exactly such a shared tree.  So:
;; read both, write ours.  PEP 3147's cache tag is there for this.
;; ============================================================================
IOP_BUF   equ 8
IOP_LEN   equ 16
IOP_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
DEF_FUNC_LOCAL im_open_pyc, IOP_FRAME
    mov [rbp - IOP_BUF], rdi
    mov [rbp - IOP_LEN], rsi
    cmp rsi, IM_TAG_LEN
    jb .iop_none

    lea rsi, [rel im_ap_pyc_tag]
    mov rdi, [rbp - IOP_BUF]
    add rdi, [rbp - IOP_LEN]
    sub rdi, IM_TAG_LEN
    mov edx, IM_TAG_LEN
    call ap_memcpy
    mov rdi, [rbp - IOP_BUF]
    xor esi, esi                        ; O_RDONLY
    xor edx, edx
    call sys_open
    test rax, rax
    js .iop_second
    mov rdi, rax
    mov rsi, [rbp - IOP_BUF]
    call sd_pyc_ok
    test rax, rax
    jnz .iop_out

.iop_second:
    lea rsi, [rel im_cp_pyc_tag]
    mov rdi, [rbp - IOP_BUF]
    add rdi, [rbp - IOP_LEN]
    sub rdi, IM_TAG_LEN
    mov edx, IM_TAG_LEN
    call ap_memcpy
    mov rdi, [rbp - IOP_BUF]
    xor esi, esi
    xor edx, edx
    call sys_open
    test rax, rax
    js .iop_none
    mov rdi, rax
    mov rsi, [rbp - IOP_BUF]
    call sd_pyc_ok
    test rax, rax
    jnz .iop_out

.iop_none:
    mov rax, -1
.iop_out:
    leave
    ret
END_FUNC im_open_pyc

;; ============================================================================
;; import_search_dirs(PyListObject *dirs, const char *leaf, int64_t leaf_len) -> int
;; Search a list of directory strings for a module named 'leaf'.
;; Tries: <dir>/<leaf>/__pycache__/__init__.cpython-312.pyc (package)
;;        <dir>/__pycache__/<leaf>.cpython-312.pyc (module)
;;        <dir>/<leaf>.cpython-312.pyc (module, no __pycache__)
;; On success, sets import_path_buf_ptr contents and returns 1 (package) or 2 (module).
;; On failure returns 0.
;; ============================================================================

;; ============================================================================
;; Frame layout for import_search_dirs
;; ============================================================================
SD_DIRS     equ 8             ; dirs list
SD_LEAF     equ 16            ; leaf cstr
SD_LEAFLEN  equ 24            ; leaf length
SD_FULLPATH equ 32            ; optional full path component (with slashes)
SD_IDX      equ 40            ; current search index
SD_COUNT    equ 48            ; number of dirs
SD_FRAME    equ 56          ; + 5 pushes = 96

DEF_FUNC import_search_dirs, SD_FRAME
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov [rbp - SD_DIRS], rdi
    mov [rbp - SD_LEAF], rsi
    mov [rbp - SD_LEAFLEN], rdx
    mov qword [rbp - SD_FULLPATH], 0

    ; Get list size and item array
    mov r14, [rdi + PyListObject.ob_size]   ; count
    mov [rbp - SD_COUNT], r14
    mov qword [rbp - SD_IDX], 0

.sd_loop:
    mov rax, [rbp - SD_IDX]
    cmp rax, [rbp - SD_COUNT]
    jge .sd_not_found

    ; Get dir string (fat list: 16-byte stride)
    mov rdi, [rbp - SD_DIRS]
    mov rcx, [rdi + PyListObject.ob_item]
    mov rax, [rbp - SD_IDX]
    mov rbx, [rcx + rax * 8]      ; rbx = dir str obj payload
    V_UNPACK rbx, r8
    cmp r8d, TAG_SMALLINT
    je .sd_next                 ; skip SmallInts
    test rbx, rbx
    jz .sd_next

    ; Build path in import_path_buf_ptr
    mov r12, [rel import_path_buf_ptr]  ; r12 = dest buf

    ; Bound the assembled path before writing any of it.  Nothing checked
    ; it: a sys.path entry longer than the buffer memcpy'd straight past the
    ; end of the 8192-byte heap block, so sys.path.insert(0, "A"*9000)
    ; followed by any import corrupted the heap.  Too long simply means the
    ; module is not findable here.
    lea rsi, [rbx + PyStrObject.data]
    mov r13, [rbx + PyStrObject.ob_size] ; r13 = offset (dir length)
    mov rax, r13
    add rax, [rbp - SD_LEAFLEN]
    add rax, IM_PATH_MARGIN
    cmp rax, PATHBUF_SIZE
    jae .sd_next

    ; Copy dir to buffer
    test r13, r13
    jz .sd_no_dir
    mov rdi, r12
    mov rdx, r13
    call ap_memcpy
.sd_no_dir:

    ; Append '/' if dir non-empty
    test r13, r13
    jz .sd_no_slash
    mov byte [r12 + r13], '/'
    inc r13
.sd_no_slash:
    ; r13 = current write offset

    ; --- Pattern 1: <dir>/<leaf>/__pycache__/__init__.cpython-312.pyc ---
    ; Append leaf name
    mov rdi, r12
    add rdi, r13
    mov rsi, [rbp - SD_LEAF]
    mov rdx, [rbp - SD_LEAFLEN]
    mov r15, rdx                ; save leaf len
    call ap_memcpy
    lea r14, [r13 + r15]       ; r14 = offset after leaf

    ; Append suffix
    mov rdi, r12
    add rdi, r14
    lea rsi, [rel im_pkg_pyc_suffix]
    mov rdx, im_pkg_pyc_suffix_len
    call ap_memcpy
    add r14, im_pkg_pyc_suffix_len
    mov byte [r12 + r14], 0

    mov rdi, r12
    mov rsi, r14
    call im_open_pyc
    test rax, rax
    jns .sd_found_package

.sd_p2:
    ; --- Pattern 2: <dir>/__pycache__/<leaf>.cpython-312.pyc ---
    ; Rebuild from dir offset (r13 already has dir+slash offset)
    ; Re-read r13 from dir
    mov r13, [rbx + PyStrObject.ob_size]
    test r13, r13
    jz .sd_p2_no_slash
    inc r13                     ; account for '/'
.sd_p2_no_slash:

    ; Append "__pycache__/"
    mov rdi, r12
    add rdi, r13
    lea rsi, [rel im_pycache_prefix]
    mov rdx, im_pycache_prefix_len
    call ap_memcpy
    add r13, im_pycache_prefix_len

    ; Append leaf name
    mov rdi, r12
    add rdi, r13
    mov rsi, [rbp - SD_LEAF]
    mov rdx, [rbp - SD_LEAFLEN]
    call ap_memcpy
    add r13, [rbp - SD_LEAFLEN]

    ; Append ".cpython-312.pyc"
    mov rdi, r12
    add rdi, r13
    lea rsi, [rel im_pyc_suffix]
    mov rdx, im_pyc_suffix_len
    call ap_memcpy
    add r13, im_pyc_suffix_len
    mov byte [r12 + r13], 0

    mov rdi, r12
    mov rsi, r13
    call im_open_pyc
    test rax, rax
    jns .sd_found_module

.sd_p3:
    ; --- Pattern 3: <dir>/<leaf>.cpython-312.pyc ---
    mov r13, [rbx + PyStrObject.ob_size]
    test r13, r13
    jz .sd_p3_no_slash
    inc r13
.sd_p3_no_slash:

    ; Append leaf name
    mov rdi, r12
    add rdi, r13
    mov rsi, [rbp - SD_LEAF]
    mov rdx, [rbp - SD_LEAFLEN]
    call ap_memcpy
    add r13, [rbp - SD_LEAFLEN]

    ; Append ".cpython-312.pyc"
    mov rdi, r12
    add rdi, r13
    lea rsi, [rel im_pyc_suffix]
    mov rdx, im_pyc_suffix_len
    call ap_memcpy
    add r13, im_pyc_suffix_len
    mov byte [r12 + r13], 0

    mov rdi, r12
    mov rsi, r13
    call im_open_pyc
    test rax, rax
    jns .sd_found_module

.sd_p4:
    ; --- Pattern 4: <dir>/<leaf>/__init__.py (a package, from source) ---
    ; The source patterns come last, so a .pyc that is already there still
    ; wins and nothing an existing user has changes behaviour.
    mov r13, [rbx + PyStrObject.ob_size]
    test r13, r13
    jz .sd_p4_no_slash
    inc r13
.sd_p4_no_slash:
    mov rdi, r12
    add rdi, r13
    mov rsi, [rbp - SD_LEAF]
    mov rdx, [rbp - SD_LEAFLEN]
    call ap_memcpy
    add r13, [rbp - SD_LEAFLEN]

    mov rdi, r12
    add rdi, r13
    lea rsi, [rel im_pkg_py_suffix]
    mov rdx, im_pkg_py_suffix_len
    call ap_memcpy
    add r13, im_pkg_py_suffix_len
    mov byte [r12 + r13], 0

    mov rdi, r12
    xor esi, esi
    xor edx, edx
    call sys_open
    test rax, rax
    jns .sd_found_package

    ; --- Pattern 5: <dir>/<leaf>.py (a module, from source) ---
    mov r13, [rbx + PyStrObject.ob_size]
    test r13, r13
    jz .sd_p5_no_slash
    inc r13
.sd_p5_no_slash:
    mov rdi, r12
    add rdi, r13
    mov rsi, [rbp - SD_LEAF]
    mov rdx, [rbp - SD_LEAFLEN]
    call ap_memcpy
    add r13, [rbp - SD_LEAFLEN]

    mov rdi, r12
    add rdi, r13
    lea rsi, [rel im_py_suffix]
    mov rdx, im_py_suffix_len
    call ap_memcpy
    add r13, im_py_suffix_len
    mov byte [r12 + r13], 0

    mov rdi, r12
    xor esi, esi
    xor edx, edx
    call sys_open
    test rax, rax
    jns .sd_found_module

    ; --- Pattern 5b: <dir>/<leaf>.pyc (CPython's sourceless form) ---
    ; Last, as CPython's FileFinder puts it last: a .py beside it wins.  The
    ; tagged "<leaf>.cpython-312.pyc" above is what this tree writes; a bare
    ; "<leaf>.pyc" is what a distributor ships with the sources stripped, and
    ; what `os.rename(cache_from_source(p), p + "c")` leaves behind.
    mov r13, [rbx + PyStrObject.ob_size]
    test r13, r13
    jz .sd_p5b_no_slash
    inc r13
.sd_p5b_no_slash:
    mov rdi, r12
    add rdi, r13
    mov rsi, [rbp - SD_LEAF]
    mov rdx, [rbp - SD_LEAFLEN]
    call ap_memcpy
    add r13, [rbp - SD_LEAFLEN]

    mov rdi, r12
    add rdi, r13
    lea rsi, [rel im_legacy_pyc_suffix]
    mov rdx, im_legacy_pyc_suffix_len
    call ap_memcpy
    add r13, im_legacy_pyc_suffix_len
    mov byte [r12 + r13], 0

    mov rdi, r12
    xor esi, esi
    xor edx, edx
    call sys_open
    test rax, rax
    js .sd_next
    mov rdi, rax
    mov rsi, r12
    call sd_pyc_ok
    test eax, eax
    jnz .sd_found_module

.sd_next:
    inc qword [rbp - SD_IDX]
    jmp .sd_loop

.sd_found_package:
    ; Close the test fd
    mov rdi, rax
    call sys_close
    mov eax, 1                  ; return 1 = package
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.sd_found_module:
    ; Close the test fd
    mov rdi, rax
    call sys_close
    mov eax, 2                  ; return 2 = module
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.sd_not_found:
    xor eax, eax               ; return 0 = not found
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC import_search_dirs

;; ============================================================================
;; import_search_syspath(PyListObject *sys_path, const char *leaf, int64_t leaf_len,
;;                       const char *full_component) -> int
;; Searches sys.path for a module. For dotted names, full_component has slashes.
;; Tries patterns:
;;   <dir>/<full_component>/__pycache__/__init__.cpython-312.pyc (package)
;;   <dir>/__pycache__/<leaf>.cpython-312.pyc (module)
;;   <dir>/<leaf>.cpython-312.pyc (module, no __pycache__)
;; Returns 1 (package), 2 (module), 3 (a PEP 420 namespace package, whose
;; portion directories are left in import_ns_portions), or 0 (not found).
;;
;; The namespace case is the last pattern and it does NOT return: a directory
;; with no __init__.py is a package under PEP 420, but only if nothing else on
;; the whole of sys.path answers to the name.  A regular package or module
;; WINS wherever it sits, which is the opposite of the first-match rule every
;; other pattern follows -- so a matching bare directory is recorded and the
;; scan continues, and the portions are the answer only if the loop runs out.
;; They accumulate, because a namespace package's __path__ is every matching
;; directory rather than the first; that is what lets two distributions each
;; ship part of one package, and it is the point of the PEP.
;; ============================================================================

SS_DIRS     equ 8
SS_LEAF     equ 16
SS_LEAFLEN  equ 24
SS_FULL     equ 32            ; full path component (dots->slashes)
SS_IDX      equ 40
SS_COUNT    equ 48
SS_STAT     equ 56 + 144      ; STAT_SIZE, for the is-it-a-directory test
SS_DIRLEN   equ SS_STAT + 8   ; how long <dir>/<full> came out
SS_FRAME    equ ((SS_DIRLEN + 15) / 16) * 16 + 8   ; + 5 pushes = 16-aligned

DEF_FUNC import_search_syspath, SS_FRAME
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov [rbp - SS_DIRS], rdi
    mov [rbp - SS_LEAF], rsi
    mov [rbp - SS_LEAFLEN], rdx
    mov [rbp - SS_FULL], rcx

    mov r14, [rdi + PyListObject.ob_size]
    mov [rbp - SS_COUNT], r14
    mov qword [rbp - SS_IDX], 0

    ; Any portions a previous search collected are not this one's.
    call import_ns_portions_clear

.ss_loop:
    mov rax, [rbp - SS_IDX]
    cmp rax, [rbp - SS_COUNT]
    jge .ss_not_found

    ; Get dir string (fat list: 16-byte stride)
    mov rdi, [rbp - SS_DIRS]
    mov rcx, [rdi + PyListObject.ob_item]
    mov rax, [rbp - SS_IDX]
    mov rbx, [rcx + rax * 8]      ; rbx = dir str obj payload
    V_UNPACK rbx, r8
    cmp r8d, TAG_SMALLINT
    je .ss_next                 ; skip SmallInts
    test rbx, rbx
    jz .ss_next

    mov r12, [rel import_path_buf_ptr]  ; dest buf

    ; Same bound as the search loop above.
    lea rsi, [rbx + PyStrObject.data]
    mov r13, [rbx + PyStrObject.ob_size]
    mov rax, r13
    add rax, [rbp - SS_LEAFLEN]
    add rax, IM_PATH_MARGIN
    cmp rax, PATHBUF_SIZE
    jae .ss_next

    ; Copy dir to buffer
    test r13, r13
    jz .ss_no_dir
    mov rdi, r12
    mov rdx, r13
    call ap_memcpy
.ss_no_dir:
    test r13, r13
    jz .ss_no_slash
    mov byte [r12 + r13], '/'
    inc r13
.ss_no_slash:

    ; --- Pattern 1: <dir>/<full>/__pycache__/__init__.cpython-312.pyc ---
    ; Append full component (dots->slashes)
    mov rdi, r12
    add rdi, r13
    mov rsi, [rbp - SS_FULL]
    push r13                    ; save dir offset
    mov rdi, rsi                ; strlen(full)
    call ap_strlen
    mov r15, rax                ; r15 = full component length
    pop r13
    ; The dotted component can be longer than the leaf checked above.
    mov rax, r13
    add rax, r15
    add rax, IM_PATH_MARGIN
    cmp rax, PATHBUF_SIZE
    jae .ss_next

    mov rdi, r12
    add rdi, r13
    mov rsi, [rbp - SS_FULL]
    mov rdx, r15
    call ap_memcpy
    lea r14, [r13 + r15]       ; offset after full component

    ; Append package suffix
    mov rdi, r12
    add rdi, r14
    lea rsi, [rel im_pkg_pyc_suffix]
    mov rdx, im_pkg_pyc_suffix_len
    call ap_memcpy
    add r14, im_pkg_pyc_suffix_len
    mov byte [r12 + r14], 0

    mov rdi, r12
    mov rsi, r14
    call im_open_pyc
    test rax, rax
    jns .ss_found_package
.ss_after_pyc0:

    ; --- Pattern 2: <dir>/__pycache__/<leaf>.cpython-312.pyc ---
    mov r13, [rbx + PyStrObject.ob_size]
    test r13, r13
    jz .ss_p2_no_slash
    inc r13
.ss_p2_no_slash:

    mov rdi, r12
    add rdi, r13
    lea rsi, [rel im_pycache_prefix]
    mov rdx, im_pycache_prefix_len
    call ap_memcpy
    add r13, im_pycache_prefix_len

    mov rdi, r12
    add rdi, r13
    mov rsi, [rbp - SS_LEAF]
    mov rdx, [rbp - SS_LEAFLEN]
    call ap_memcpy
    add r13, [rbp - SS_LEAFLEN]

    mov rdi, r12
    add rdi, r13
    lea rsi, [rel im_pyc_suffix]
    mov rdx, im_pyc_suffix_len
    call ap_memcpy
    add r13, im_pyc_suffix_len
    mov byte [r12 + r13], 0

    mov rdi, r12
    mov rsi, r13
    call im_open_pyc
    test rax, rax
    jns .ss_found_module
.ss_after_pyc1:

    ; --- Pattern 3: <dir>/<leaf>.cpython-312.pyc ---
    mov r13, [rbx + PyStrObject.ob_size]
    test r13, r13
    jz .ss_p3_no_slash
    inc r13
.ss_p3_no_slash:

    mov rdi, r12
    add rdi, r13
    mov rsi, [rbp - SS_LEAF]
    mov rdx, [rbp - SS_LEAFLEN]
    call ap_memcpy
    add r13, [rbp - SS_LEAFLEN]

    mov rdi, r12
    add rdi, r13
    lea rsi, [rel im_pyc_suffix]
    mov rdx, im_pyc_suffix_len
    call ap_memcpy
    add r13, im_pyc_suffix_len
    mov byte [r12 + r13], 0

    mov rdi, r12
    mov rsi, r13
    call im_open_pyc
    test rax, rax
    jns .ss_found_module
.ss_after_pyc2:

    ; --- Pattern 4: <dir>/<full>/__init__.py (a package, from source) ---
    mov r13, [rbx + PyStrObject.ob_size]
    test r13, r13
    jz .ss_p4_no_slash
    inc r13
.ss_p4_no_slash:
    mov rdi, r12
    add rdi, r13
    mov rsi, [rbp - SS_FULL]
    mov rdx, r15                ; the dotted component's length, from pattern 1
    call ap_memcpy
    add r13, r15

    mov rdi, r12
    add rdi, r13
    lea rsi, [rel im_pkg_py_suffix]
    mov rdx, im_pkg_py_suffix_len
    call ap_memcpy
    add r13, im_pkg_py_suffix_len
    mov byte [r12 + r13], 0

    mov rdi, r12
    xor esi, esi
    xor edx, edx
    call sys_open
    test rax, rax
    jns .ss_found_package

    ; --- Pattern 5: <dir>/<leaf>.py (a module, from source) ---
    mov r13, [rbx + PyStrObject.ob_size]
    test r13, r13
    jz .ss_p5_no_slash
    inc r13
.ss_p5_no_slash:
    mov rdi, r12
    add rdi, r13
    mov rsi, [rbp - SS_LEAF]
    mov rdx, [rbp - SS_LEAFLEN]
    call ap_memcpy
    add r13, [rbp - SS_LEAFLEN]

    mov rdi, r12
    add rdi, r13
    lea rsi, [rel im_py_suffix]
    mov rdx, im_py_suffix_len
    call ap_memcpy
    add r13, im_py_suffix_len
    mov byte [r12 + r13], 0

    mov rdi, r12
    xor esi, esi
    xor edx, edx
    call sys_open
    test rax, rax
    jns .ss_found_module

    ; --- Pattern 5b: <dir>/<leaf>.pyc (CPython's sourceless form) ---
    ; Last of the file patterns, as CPython's FileFinder has it: a .py beside
    ; it wins.  See the same pattern in import_search_dirs for why it exists.
    mov r13, [rbx + PyStrObject.ob_size]
    test r13, r13
    jz .ss_p5b_no_slash
    inc r13
.ss_p5b_no_slash:
    mov rdi, r12
    add rdi, r13
    mov rsi, [rbp - SS_LEAF]
    mov rdx, [rbp - SS_LEAFLEN]
    call ap_memcpy
    add r13, [rbp - SS_LEAFLEN]

    mov rdi, r12
    add rdi, r13
    lea rsi, [rel im_legacy_pyc_suffix]
    mov rdx, im_legacy_pyc_suffix_len
    call ap_memcpy
    add r13, im_legacy_pyc_suffix_len
    mov byte [r12 + r13], 0

    mov rdi, r12
    xor esi, esi
    xor edx, edx
    call sys_open
    test rax, rax
    js .ss_p6
    mov rdi, rax
    mov rsi, r12
    call sd_pyc_ok
    test eax, eax
    jnz .ss_found_module

.ss_p6:
    ; --- Pattern 6: <dir>/<full> is a DIRECTORY (PEP 420) ---
    ; Recorded rather than returned; see the header.  Nothing here can be a
    ; regular package, because patterns 1 and 4 have already asked this same
    ; directory for its __init__.
    mov r13, [rbx + PyStrObject.ob_size]
    test r13, r13
    jz .ss_p6_no_slash
    inc r13
.ss_p6_no_slash:
    mov rdi, r12
    add rdi, r13
    mov rsi, [rbp - SS_FULL]
    mov rdx, r15                ; the dotted component's length, from pattern 1
    call ap_memcpy
    add r13, r15
    mov byte [r12 + r13], 0
    mov [rbp - SS_DIRLEN], r13

    mov rdi, r12
    lea rsi, [rbp - SS_STAT]
    call sys_stat
    test rax, rax
    js .ss_next
    mov eax, [rbp - SS_STAT + StatBuf.st_mode]   ; 32-bit field
    and eax, S_IFMT
    cmp eax, S_IFDIR
    jne .ss_next
    mov rdi, r12
    mov rsi, [rbp - SS_DIRLEN]
    call import_ns_portions_add

.ss_next:
    inc qword [rbp - SS_IDX]
    jmp .ss_loop

.ss_found_package:
    mov rdi, rax
    call sys_close
    mov eax, 1
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.ss_found_module:
    mov rdi, rax
    call sys_close
    mov eax, 2
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.ss_not_found:
    ; Nothing regular answered to the name anywhere, so the bare directories
    ; recorded along the way are the package.
    mov rax, [rel import_ns_portions]
    test rax, rax
    jz .ss_really_not_found
    cmp qword [rax + PyListObject.ob_size], 0
    je .ss_really_not_found
    mov eax, 3
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
.ss_really_not_found:
    xor eax, eax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC import_search_syspath

;; ============================================================================
;; import_ns_portions_clear() -> nothing; drops whatever the last search
;;   collected, so a search never inherits another's portions
;;
;; The PEP 420 portions live in a global between import_search_syspath and
;; the caller that turns them into a module.  A global rather than an
;; out-parameter because the path itself already travels that way, in
;; import_path_buf_ptr, and the search's answer is an int -- one more channel
;; of the shape already there rather than a new one.
;; ============================================================================
DEF_FUNC_LOCAL import_ns_portions_clear
    mov rdi, [rel import_ns_portions]
    test rdi, rdi
    jz .inpc_done
    mov qword [rel import_ns_portions], 0
    call obj_decref
.inpc_done:
    leave
    ret
END_FUNC import_ns_portions_clear

;; ============================================================================
;; import_ns_portions_add(rdi = a directory path, rsi = its length)
;;   -> nothing; the path is appended to the portion list, which is built on
;;      first use.  A failure to allocate leaves the list as it was, and the
;;      search then answers "not found" rather than a short namespace package.
;; ============================================================================
INPA_PATH equ 8
INPA_LEN  equ 16
INPA_STR  equ 24
INPA_FRAME equ 32           ; + 0 pushes = 32, 16-aligned
DEF_FUNC_LOCAL import_ns_portions_add, INPA_FRAME
    mov [rbp - INPA_PATH], rdi
    mov [rbp - INPA_LEN], rsi

    mov rax, [rel import_ns_portions]
    test rax, rax
    jnz .inpa_have_list
    xor edi, edi
    call list_new
    test rax, rax
    jz .inpa_done
    mov [rel import_ns_portions], rax
.inpa_have_list:
    mov rdi, [rbp - INPA_PATH]
    mov rsi, [rbp - INPA_LEN]
    call str_new_heap
    test rax, rax
    jz .inpa_done
    mov [rbp - INPA_STR], rax
    mov rdi, [rel import_ns_portions]
    mov rsi, rax
    call list_append
    ; list_append took its own reference.
    mov rdi, [rbp - INPA_STR]
    call obj_decref
.inpa_done:
    leave
    ret
END_FUNC import_ns_portions_add

;; ============================================================================
;; import_make_namespace(rdi = the dotted name, as a str) -> PyObject*
;;   the new module, registered in sys.modules, or 0
;;
;; A PEP 420 namespace package: the directories import_search_syspath
;; collected become its __path__, and there is no code to run, because there
;; is no __init__.py -- that is what makes it one.  Everything else a module
;; carries is set the way import_load_module sets it, with __file__ None
;; rather than absent, which is what CPython leaves on a namespace module and
;; what a caller that asks for it sees.
;; ============================================================================
IMN_NAME  equ 8
IMN_DICT  equ 16
IMN_MOD   equ 24
IMN_KEY   equ 32
IMN_FRAME equ 48            ; + 0 pushes = 48, 16-aligned
DEF_FUNC_LOCAL import_make_namespace, IMN_FRAME
    mov [rbp - IMN_NAME], rdi

    call dict_new
    test rax, rax
    jz .imn_fail
    mov [rbp - IMN_DICT], rax

    ; __name__ = the dotted name
    lea rdi, [rel im_dunder_name]
    mov rsi, [rbp - IMN_NAME]
    call .imn_set
    ; __package__ = the same: a namespace package IS a package
    lea rdi, [rel im_dunder_package]
    mov rsi, [rbp - IMN_NAME]
    call .imn_set
    ; __path__ = the portions
    lea rdi, [rel im_dunder_path]
    mov rsi, [rel import_ns_portions]
    call .imn_set
    ; __file__, __loader__ and __spec__ are all None here.  None rather than
    ; absent for __file__: CPython leaves the name bound, and code that asks
    ; whether a module has a file reads None rather than catching.
    lea rdi, [rel im_dunder_file]
    lea rsi, [rel none_singleton]
    call .imn_set
    lea rdi, [rel im_dunder_loader]
    lea rsi, [rel none_singleton]
    call .imn_set
    lea rdi, [rel im_dunder_spec]
    lea rsi, [rel none_singleton]
    call .imn_set
    lea rdi, [rel im_dunder_builtins]
    mov rsi, [rel builtins_dict_global]
    call .imn_set

    mov rdi, [rbp - IMN_NAME]
    mov rsi, [rbp - IMN_DICT]
    call module_new
    test rax, rax
    jz .imn_fail_dict
    mov [rbp - IMN_MOD], rax

    mov rdi, [rel sys_modules_dict]
    mov rsi, [rbp - IMN_NAME]
    mov rdx, rax
    call dict_set

    ; The module owns the dict now; release what dict_new gave us.
    mov rdi, [rbp - IMN_DICT]
    call obj_decref
    mov rax, [rbp - IMN_MOD]
    leave
    ret

.imn_fail_dict:
    mov rdi, [rbp - IMN_DICT]
    call obj_decref
.imn_fail:
    xor eax, eax
    leave
    ret

;; rdi = the key, as a C string; rsi = the value.  The key is interned into a
;; str, set, and released -- the shape every dunder store above it uses.
.imn_set:
    mov [rbp - IMN_KEY], rsi
    call str_from_cstr_heap
    test rax, rax
    jz .imn_set_done
    mov rdi, [rbp - IMN_DICT]
    mov rsi, rax
    mov rdx, [rbp - IMN_KEY]
    push rax
    push rax                    ; a pair, so the call stays 16-byte aligned
    call dict_set
    pop rdi
    pop rdi
    call obj_decref
.imn_set_done:
    ret
END_FUNC import_make_namespace

;; ============================================================================
;; import_abspath(rdi = a path as a C string) -> rax = an absolute path in a
;;   static buffer, or rdi unchanged when it is already absolute or will not fit
;;
;; `__file__` and `__cached__` are absolute in CPython from 3.4 onward, and a
;; relative sys.path entry -- "." is what `-m` puts there -- made ours
;; relative.  test_import compares __cached__ against
;; os.path.join(os.getcwd(), ...) and saw "./__pycache__/x.pyc".
;;
;; A leading "./" is dropped rather than kept, because os.path.join produces
;; no such segment and the comparison is textual.
;; ============================================================================
IAP_PATH  equ 8
IAP_FRAME equ 24            ; + 1 push = 32, 16-aligned
global import_abspath
DEF_FUNC import_abspath, IAP_FRAME
    push rbx
    mov [rbp - IAP_PATH], rdi
    test rdi, rdi
    jz .iap_asis
    cmp byte [rdi], '/'
    je .iap_asis

    lea rdi, [rel iap_buf]
    mov esi, IAP_BUFSZ - 1
    call sys_getcwd
    test rax, rax
    js .iap_asis
    lea rdi, [rel iap_buf]
    call ap_strlen
    mov rbx, rax
    cmp rbx, 1
    jbe .iap_have_cwd                   ; "/" already ends in a slash
    lea rdi, [rel iap_buf]
    mov byte [rdi + rbx], '/'
    inc rbx
.iap_have_cwd:

    mov rsi, [rbp - IAP_PATH]
    cmp word [rsi], 0x2f2e               ; "./", little-endian
    jne .iap_copy
    add rsi, 2
.iap_copy:
    push rsi
    mov rdi, rsi
    call ap_strlen
    pop rsi
    lea rcx, [rbx + rax]
    cmp rcx, IAP_BUFSZ - 1
    jae .iap_asis
    lea rdi, [rel iap_buf]
    add rdi, rbx
    mov rdx, rax
    add rbx, rax                        ; ap_memcpy answers the DEST, not the
                                        ; length, so the sum is taken first
    call ap_memcpy
    lea rdi, [rel iap_buf]
    mov byte [rdi + rbx], 0
    mov rax, rdi
    pop rbx
    leave
    ret
.iap_asis:
    mov rax, [rbp - IAP_PATH]
    pop rbx
    leave
    ret
END_FUNC import_abspath

;; ============================================================================
;; import_load_module(PyObject *name_str, const char *path_cstr, int is_package) -> PyObject*
;; Load a .pyc file and execute it as a module
;; ============================================================================
DEF_FUNC import_load_module, IF_FRAME
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov rbx, rdi                ; name_str
    mov r12, rsi                ; path_cstr
    mov r13d, edx               ; is_package
    DUNDER_EXC_SAVE [rbp - IF_EXC]

    ; Save marshal globals
    mov rax, [rel marshal_buf]
    mov [rbp - IF_MBUF], rax
    mov rax, [rel marshal_pos]
    mov [rbp - IF_MPOS], rax
    mov rax, [rel marshal_len]
    mov [rbp - IF_MLEN], rax
    mov rax, [rel marshal_refs]
    mov [rbp - IF_MREFS], rax
    mov rax, [rel marshal_ref_count]
    mov [rbp - IF_MRCNT], rax
    mov rax, [rel marshal_ref_cap]
    mov [rbp - IF_MRCAP], rax

    ; Reset marshal refs so inner import allocates fresh arrays
    mov qword [rel marshal_refs], 0
    mov qword [rel marshal_ref_count], 0
    mov qword [rel marshal_ref_cap], 0

    ; Read the file -> code object; a .py is compiled on the spot.
    mov rdi, r12
    call code_from_path
    test rax, rax
    jz .load_failed
    mov r14, rax                ; r14 = code object

    ; Cache the bytecode when the finder handed over a .py.  Without this,
    ; lib/ is recompiled from source on every start -- and pyc_write_cache
    ; itself decides whether the path is a source file and whether
    ; sys.dont_write_bytecode forbids it.
    extern pyc_write_cache
    mov rdi, r12
    mov rsi, r14
    call pyc_write_cache

    ; Free inner import's marshal refs array (if allocated)
    mov rdi, [rel marshal_refs]
    test rdi, rdi
    jz .skip_inner_refs_free
    call ap_free
.skip_inner_refs_free:

    ; Restore marshal globals
    mov rax, [rbp - IF_MBUF]
    mov [rel marshal_buf], rax
    mov rax, [rbp - IF_MPOS]
    mov [rel marshal_pos], rax
    mov rax, [rbp - IF_MLEN]
    mov [rel marshal_len], rax
    mov rax, [rbp - IF_MREFS]
    mov [rel marshal_refs], rax
    mov rax, [rbp - IF_MRCNT]
    mov [rel marshal_ref_count], rax
    mov rax, [rbp - IF_MRCAP]
    mov [rel marshal_ref_cap], rax

    ; Create module dict
    call dict_new
    mov r15, rax                ; r15 = module dict

    ; Set __name__
    lea rdi, [rel im_dunder_name]
    call str_from_cstr_heap
    push rax
    mov rdi, r15
    mov rsi, rax
    mov rdx, rbx                ; name_str
    call dict_set
    pop rdi
    call obj_decref

    ; Set __file__
    ;
    ; The SOURCE path, not the cache file the code actually came out of.
    ; CPython records the .py even when it executes a cached .pyc -- it is
    ; what a module's repr prints, what inspect.getsource opens, and what a
    ; traceback through the module names -- and this recorded whichever file
    ; the search matched, so every import through __pycache__ answered
    ; ".../__pycache__/m.cpython-312.pyc".
    mov rdi, r12                ; path cstr
    call import_source_path     ; -> the .py, or r12 unchanged
    mov rdi, rax
    call import_abspath
    mov rdi, rax
    call str_from_cstr_heap
    push rax                    ; file str
    lea rdi, [rel im_dunder_file]
    call str_from_cstr_heap
    push rax
    mov rdi, r15
    mov rsi, rax
    mov rdx, [rsp + 8]
    call dict_set
    pop rdi
    call obj_decref
    pop rdi
    call obj_decref

    ; Set __cached__
    ;
    ; The other half of __file__: where the bytecode is, or would be.  A .pyc
    ; the finder matched IS its own cache file; a .py names the __pycache__
    ; entry beside it whether or not one has been written yet, which is what
    ; CPython records and what importlib and the pycache tests read back.
    mov rdi, r12                        ; path cstr
    extern pyc_cache_path
    call pyc_cache_path
    test rax, rax
    jnz .have_cached
    mov rax, r12                        ; not a source: it is its own cache
.have_cached:
    mov rdi, rax
    call import_abspath
    mov rdi, rax
    call str_from_cstr_heap
    push rax
    lea rdi, [rel im_dunder_cached]
    call str_from_cstr_heap
    push rax
    mov rdi, r15
    mov rsi, rax
    mov rdx, [rsp + 8]
    call dict_set
    pop rdi
    call obj_decref
    pop rdi
    call obj_decref

    ; Set __loader__ = None
    lea rdi, [rel im_dunder_loader]
    call str_from_cstr_heap
    push rax
    mov rdi, r15
    mov rsi, rax
    lea rdx, [rel none_singleton]
    call dict_set
    pop rdi
    call obj_decref

    ; Set __spec__ = None
    lea rdi, [rel im_dunder_spec]
    call str_from_cstr_heap
    push rax
    mov rdi, r15
    mov rsi, rax
    lea rdx, [rel none_singleton]
    call dict_set
    pop rdi
    call obj_decref

    ; Set __package__
    test r13d, r13d
    jz .set_parent_package

    ; Package: __package__ = name, __path__ = [dir]
    lea rdi, [rel im_dunder_package]
    call str_from_cstr_heap
    push rax
    mov rdi, r15
    mov rsi, rax
    mov rdx, rbx                ; name_str
    call dict_set
    pop rdi
    call obj_decref

    ; Compute package directory from path.  A cached package is
    ; ".../pkg/__pycache__/__init__.cpython-312.pyc" -- two components to
    ; strip -- while a source package is ".../pkg/__init__.py", which is one.
    ; Either way we want ".../pkg".
    mov rdi, r12
    call path_is_source
    push rax
    mov rdi, r12
    call ap_strlen
    pop r8
    mov rcx, rax
    dec rcx
.find_slash1:
    dec rcx
    js .use_dot_path
    cmp byte [r12 + rcx], '/'
    jne .find_slash1
    ; Found the slash before __init__.*; for a source package that is already
    ; the package directory.
    test r8, r8
    jnz .have_pkg_dir
    dec rcx
.find_slash2:
    dec rcx
    js .use_dot_path
    cmp byte [r12 + rcx], '/'
    jne .find_slash2
    ; Found the second slash, the one before __pycache__.
.have_pkg_dir:
    ; pkg dir = path[0..rcx]
    mov rdi, r12
    mov rsi, rcx
    call str_new_heap
    jmp .set_path

.use_dot_path:
    lea rdi, [rel im_dot]
    call str_from_cstr_heap

.set_path:
    push rax                    ; pkg dir str

    ; __path__ = [pkg_dir]
    xor edi, edi
    call list_new
    mov r8, rax                 ; list
    push r8
    mov rdi, r8
    mov rsi, [rsp + 8]         ; pkg dir str
    call list_append
    ; DECREF pkg dir str
    mov rdi, [rsp + 8]
    call obj_decref

    ; Set __path__ in dict
    lea rdi, [rel im_dunder_path]
    call str_from_cstr_heap
    push rax
    mov rdi, r15
    mov rsi, rax
    mov rdx, [rsp + 8]         ; list
    call dict_set
    pop rdi                     ; key
    call obj_decref
    pop rdi                     ; list
    call obj_decref
    add rsp, 8                  ; pop saved pkg dir str (already decref'd)

    jmp .create_module

.set_parent_package:
    ; Non-package: __package__ = parent name (before last '.')
    lea rdi, [rbx + PyStrObject.data]
    mov rcx, [rbx + PyStrObject.ob_size]
    ; Find last dot
    mov rdx, rcx
.find_last_dot:
    dec rdx
    js .no_parent_pkg
    cmp byte [rdi + rdx], '.'
    jne .find_last_dot

    ; Parent package = name[0..rdx]
    lea rdi, [rbx + PyStrObject.data]
    mov rsi, rdx
    call str_new_heap
    jmp .store_package

.no_parent_pkg:
    ; Top-level module: __package__ = ""
    lea rdi, [rel im_empty]
    call str_from_cstr_heap

.store_package:
    push rax
    lea rdi, [rel im_dunder_package]
    call str_from_cstr_heap
    push rax
    mov rdi, r15
    mov rsi, rax
    mov rdx, [rsp + 8]
    call dict_set
    pop rdi
    call obj_decref
    pop rdi
    call obj_decref

.create_module:
    ; Create module object
    mov rdi, rbx                ; name
    mov rsi, r15                ; dict
    call module_new
    mov r13, rax                ; r13 = module object (reuse r13, is_package no longer needed)

    ; Register in sys.modules BEFORE execution (circular import safety)
    mov rdi, [rel sys_modules_dict]
    mov rsi, rbx                ; name_str
    mov rdx, r13
    call dict_set

    ; Set __builtins__ in module dict
    lea rdi, [rel im_dunder_builtins]
    call str_from_cstr_heap
    push rax
    mov rdi, r15
    mov rsi, rax
    mov rdx, [rel builtins_dict_global]
    call dict_set
    pop rdi
    call obj_decref

    ; Execute module code
    ; frame_new(code, globals=mod_dict, builtins, locals=mod_dict)
    mov rdi, r14                ; code
    mov rsi, r15                ; globals = module dict
    mov rdx, [rel builtins_dict_global]  ; builtins
    mov rcx, r15                ; locals = module dict
    call frame_new
    mov r12, rax                ; r12 = frame

    mov rdi, r12
    call eval_frame
    V_UNPACK rax, rdx           ; eval_frame returns a Value
    ; A module body that raised returns a NULL Value with current_exception
    ; set.  This used to be discarded -- "rax = return value (ignore)" -- so
    ; the module was returned as if it had loaded, the exception stayed
    ; pending, and the importer's own try/except never saw it.  Every other
    ; eval_frame caller propagates; see opcodes_call.asm .propagate_exc.
    test edx, edx
    jnz .body_returned
    DUNDER_RAISED [rbp - IF_EXC], .body_raised
.body_returned:
    ; XDECREF return value (tag-aware)
    mov rdi, rax
    mov rsi, rdx
    DECREF_VAL rdi, rsi
.no_retval:

    ; Free frame
    mov rdi, r12
    call frame_free

    ; DECREF code object
    mov rdi, r14
    call obj_decref

    ; The module owns the dict now; release the reference dict_new gave us.
    mov rdi, r15
    call obj_decref

    ; A module body may REPLACE itself in sys.modules, and the value bound by
    ; `import x` has to be what sys.modules holds when the body finishes, not
    ; the object that was put there before it ran.  CPython's _bootstrap._load
    ; re-reads it for exactly this reason:
    ;
    ;     module = sys.modules.pop(spec.name)
    ;     sys.modules[spec.name] = module
    ;     return module
    ;
    ; Returning the created object instead is not a cosmetic difference: the
    ; replacement idiom is how an alias module names something else (it is
    ; what `_frozen_importlib` does), and worse, the object we created has
    ; already been released by the dict_set that overwrote it -- so `mov rax,
    ; r13` could hand back freed memory.
    mov rdi, [rel sys_modules_dict]
    mov rsi, rbx                ; name_str
    call dict_get               ; borrowed Value, or 0 for a miss
    test rax, rax
    jz .fl_keep_created         ; the body deleted itself; hand back what we made
    V_TEST_PTR rax, rcx
    ja .fl_keep_created         ; not a pointer -- nothing sane to return
    cmp rax, r13
    je .fl_keep_created         ; the ordinary case: unchanged
    INCREF rax                  ; our caller owns what it gets back
    mov rdi, r13
    mov r13, rax
    call obj_decref             ; and the object we built is no longer ours
.fl_keep_created:

    ; Return module (already in sys.modules with INCREF from dict_set)
    mov rax, r13

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.load_failed:
    ; Free inner import's marshal refs array (if allocated)
    mov rdi, [rel marshal_refs]
    test rdi, rdi
    jz .skip_fail_refs_free
    call ap_free
.skip_fail_refs_free:

    ; Restore marshal globals even on failure
    mov rax, [rbp - IF_MBUF]
    mov [rel marshal_buf], rax
    mov rax, [rbp - IF_MPOS]
    mov [rel marshal_pos], rax
    mov rax, [rbp - IF_MLEN]
    mov [rel marshal_len], rax
    mov rax, [rbp - IF_MREFS]
    mov [rel marshal_refs], rax
    mov rax, [rbp - IF_MRCNT]
    mov [rel marshal_ref_count], rax
    mov rax, [rbp - IF_MRCAP]
    mov [rel marshal_ref_cap], rax

    xor eax, eax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.body_raised:
    ; Undo the whole load and hand the caller a NULL with the body's
    ; exception still pending.
    mov rdi, r12
    call frame_free
    mov rdi, r14
    call obj_decref

    ; Drop the half-built module from sys.modules, as CPython's
    ; remove_module() does, so a retry re-executes the body instead of
    ; handing back an empty module.  The body may have deleted the entry
    ; itself, so look before deleting -- dict_del raises on a missing key.
    mov rdi, [rel sys_modules_dict]
    mov rsi, rbx
    call dict_get
    test rax, rax               ; dict_get answers with a Value; 0 is the miss
    jz .br_not_cached
    mov rdi, [rel sys_modules_dict]
    mov rsi, rbx
    call dict_del
.br_not_cached:

    mov rdi, r13                ; our own reference to the module
    call obj_decref
    mov rdi, r15                ; and to its dict
    call obj_decref

    xor eax, eax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC import_load_module

;; ============================================================================
;; Data
;; ============================================================================
section .rodata

im_no_module_prefix: db "No module named '", 0
im_not_pkg_mid:     db "; '", 0
im_not_pkg_tail:    db "' is not a package", 0
im_halted_prefix:    db "import of ", 0
im_halted_suffix:    db " halted; None in sys.modules", 0
irr_package_key:    db "__package__", 0
im_builtins:        db "builtins", 0
im_dunder_name:     db "__name__", 0
im_dunder_file:     db "__file__", 0
im_dunder_cached:   db "__cached__", 0
im_dunder_loader:   db "__loader__", 0
im_dunder_spec:     db "__spec__", 0
im_dunder_package:  db "__package__", 0
im_dunder_path:     db "__path__", 0
im_dunder_builtins: db "__builtins__", 0
im_empty:           db "", 0
im_dot:             db ".", 0

; Path suffixes for module search
im_pkg_pyc_suffix:     db "/__pycache__/__init__.cpython-312.pyc", 0
im_pkg_pyc_suffix_len  equ $ - im_pkg_pyc_suffix - 1

im_pycache_prefix:     db "__pycache__/", 0
im_pycache_prefix_len  equ $ - im_pycache_prefix - 1

im_pyc_suffix:         db ".cpython-312.pyc", 0
im_pyc_suffix_len      equ $ - im_pyc_suffix - 1

; CPython's sourceless form: a .pyc beside the module rather than under
; __pycache__, which is what a stripped distribution ships.
im_legacy_pyc_suffix:     db ".pyc", 0
im_legacy_pyc_suffix_len  equ $ - im_legacy_pyc_suffix - 1

; The two cache tags im_open_pyc swaps between, without their NULs: they must
; be the same length, and they are.
im_ap_pyc_tag:         db ".apython-312.pyc"
im_cp_pyc_tag:         db ".cpython-312.pyc"
IM_TAG_LEN             equ 16

im_pkg_py_suffix:      db "/__init__.py", 0
im_pkg_py_suffix_len   equ $ - im_pkg_py_suffix - 1

im_py_suffix:          db ".py", 0
im_py_suffix_len       equ $ - im_py_suffix - 1

section .rodata
isp_suffix: db ".cpython-312.pyc", 0
isp_ap_suffix: db ".apython-312.pyc", 0
isp_marker: db "/__pycache__/", 0

section .bss
im_path_key:        resq 1      ; the interned "__path__", built on first use
ISP_BUFSZ equ 4096
isp_buf: resb ISP_BUFSZ
IAP_BUFSZ equ 4096
iap_buf: resb IAP_BUFSZ

section .bss
; The builtins module, borrowed: sys.modules holds the reference for the life
; of the interpreter.  A module-level builtin's __self__ is this, as CPython's
; is, and pickling one by name reads it.
global builtins_module_obj
builtins_module_obj: resq 1

import_path_buf_ptr: resq 1    ; malloc'd path buffer (lazy-allocated)

; The PEP 420 portion directories the last search collected, as a list of
; str, or 0.  Owned; cleared at the start of every search.
import_ns_portions: resq 1

section .bss
global import_path_override
; A list searched in place of sys.path by the interpreter's own finder, or 0.
; _impcore.create_builtin points it at the lib/ directory alone.
import_path_override: resq 1
