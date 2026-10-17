; sysmod.asm - sys module initialization
; Creates the sys module with standard attributes

%include "macros.inc"
%include "object.inc"

extern ap_malloc
extern ap_strlen
extern obj_decref
extern obj_incref
extern obj_dealloc
extern ap_strcmp
extern str_from_cstr_heap
extern str_new
extern str_type
extern int_type
extern bool_type
extern int_from_i64
extern int_to_i64
extern none_singleton
extern bool_true
extern bool_false
extern dict_new
extern str_intern
extern dict_set
extern dict_get
extern list_new
extern list_append
extern tuple_new
extern type_type
extern module_new
extern obj_call_n
extern obj_getattr_opt
extern dunder_call_1
extern fileobj_new
extern builtin_func_new
extern fatal_error
extern raise_exception

;; SYS_ADD_FUNC impl, name -- the module dict is in r15 here, not r12, so
;; MODULE_ADD_FUNC does not fit; this is the same four steps.
%macro SYS_ADD_FUNC 2
    lea rdi, [rel %1]
    lea rsi, [rel %2]
    call builtin_func_new
    push rax
    lea rdi, [rel %2]
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
%endmacro

;; SYS_ADD_FUNC_ALIAS impl, name, alias -- the same object under two names.
;; sys.excepthook and sys.__excepthook__ ARE the same object in CPython, and
;; code checks it: `sys.excepthook is sys.__excepthook__` is how a program
;; asks whether anything has replaced the hook.  Two SYS_ADD_FUNC calls made
;; two objects and that test was always False.
%macro SYS_ADD_FUNC_ALIAS 3
    lea rdi, [rel %1]
    lea rsi, [rel %2]
    call builtin_func_new
    push rax
    lea rdi, [rel %2]
    call str_from_cstr_heap
    push rax
    mov rdi, r15
    mov rsi, rax
    mov rdx, [rsp + 8]
    call dict_set
    pop rdi
    call obj_decref
    lea rdi, [rel %3]
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
%endmacro



;; SYS_ADD_INT name, value -- one integer attribute, the shape sys.maxsize is
;; written out in longhand below.
%macro SYS_ADD_INT 2
    mov rdi, %2
    call int_from_i64
    push rdx
    push rax
    lea rdi, [rel %1]
    call str_from_cstr_heap
    push rax
    push rax                    ; pad: dict_set below needs an even push list
    mov rdi, r15
    mov rsi, rax
    mov rdx, [rsp + 16]
    mov ecx, [rsp + 24]
    V_PACK rdx, rcx
    call dict_set
    pop rdi
    pop rdi
    call obj_decref             ; the key; the value is an immediate
    pop rax
    pop rax
%endmacro

;; SYS_ADD_OBJ name, obj_label -- one attribute bound to a static object.
%macro SYS_ADD_OBJ 2
    lea rdi, [rel %1]
    call str_from_cstr_heap
    push rax
    push rax                    ; pad
    mov rdi, r15
    mov rsi, rax
    lea rdx, [rel %2]
    call dict_set
    pop rdi
    pop rdi
    call obj_decref
%endmacro

;; SYS_ALIAS_SLOT name, slot -- a second name for an object already installed,
;; read back out of the .bss slot that remembers it.  sys.__stdout__ IS
;; sys.stdout in CPython, and code checks it the way it checks __excepthook__.
%macro SYS_ALIAS_SLOT 2
    lea rdi, [rel %1]
    call str_from_cstr_heap
    push rax
    push rax                    ; pad
    mov rdi, r15
    mov rsi, rax
    mov rdx, [rel %2]
    call dict_set
    pop rdi
    pop rdi
    call obj_decref
%endmacro

;; ============================================================================
;; sm_sort_names(rdi = a tuple of str) -> nothing; sorts it in place, by bytes
;;
;; An insertion sort over thirty-odd names, which is what it takes to keep
;; sys.builtin_module_names in CPython's order once two tables feed it.
;; ============================================================================
SSN_TUP   equ 8
SSN_N     equ 16
SSN_I     equ 24
SSN_J     equ 32
SSN_FRAME equ 48            ; + 1 push = 56... one word more to land right
DEF_FUNC_LOCAL sm_sort_names, 56        ; + 1 push = 64, 16-aligned
    push rbx
    mov rbx, rdi
    mov [rbp - SSN_TUP], rdi
    mov rax, [rdi + PyTupleObject.ob_size]
    mov [rbp - SSN_N], rax
    mov qword [rbp - SSN_I], 1
.ssn_outer:
    mov rax, [rbp - SSN_I]
    cmp rax, [rbp - SSN_N]
    jge .ssn_done
    mov [rbp - SSN_J], rax
.ssn_inner:
    cmp qword [rbp - SSN_J], 0
    jle .ssn_next
    mov rcx, [rbx + PyTupleObject.ob_item]
    mov rdx, [rbp - SSN_J]
    mov rdi, [rcx + rdx*8 - 8]
    mov rsi, [rcx + rdx*8]
    add rdi, PyStrObject.data
    add rsi, PyStrObject.data
    call ap_strcmp
    test eax, eax
    jle .ssn_next
    mov rcx, [rbx + PyTupleObject.ob_item]
    mov rdx, [rbp - SSN_J]
    mov rdi, [rcx + rdx*8 - 8]
    mov rsi, [rcx + rdx*8]
    mov [rcx + rdx*8 - 8], rsi
    mov [rcx + rdx*8], rdi
    dec qword [rbp - SSN_J]
    jmp .ssn_inner
.ssn_next:
    inc qword [rbp - SSN_I]
    jmp .ssn_outer
.ssn_done:
    pop rbx
    leave
    ret
END_FUNC sm_sort_names

;; ============================================================================
;; sys_module_init(int argc, char **argv) -> void
;; Initialize the sys module and register it in sys.modules
;; ============================================================================
SMI_ARGC  equ 8
SMI_ARGV  equ 16
SMI_TMP   equ 24            ; whichever object is being installed just now


;; ============================================================================
;; sm_add_exe_paths(rdi = the sys module dict) -> nothing; seven names installed
;;
;; sys.executable, sys._base_executable, the four prefix names and
;; sys._stdlib_dir, all as pathconfig.asm worked them out: the executable
;; as it was invoked (a venv's bin/python, not what it links to), and the
;; prefix of the installation or build tree the binary belongs to.  site.py
;; moves sys.prefix and sys.exec_prefix to a venv's directory when it finds
;; a pyvenv.cfg; the base_ pair stays where the standard library is.
;;
;; sys.executable must be a real path: script_helper's
;; interpreter_requires_environment() spawns `[sys.executable, '-E', ...]`
;; and an empty one killed forty of CPython's test modules at import.
;; ============================================================================
SME_DICT  equ 8
SME_STR   equ 16            ; the string being installed under several names
SME_FRAME equ 16
DEF_FUNC_LOCAL sm_add_exe_paths, SME_FRAME
    mov [rbp - SME_DICT], rdi
    extern pc_executable, pc_prefix, pc_stdlib

    lea rdi, [rel pc_executable]
    call str_from_cstr_heap
    mov [rbp - SME_STR], rax
    ; sm_add_owned takes the reference it is handed, so every use but the last
    ; of each string needs one of its own.
    mov rdi, rax
    INCREF rdi
    CSTRING rdi, "executable"
    mov rsi, [rbp - SME_STR]
    mov rdx, [rbp - SME_DICT]
    call sm_add_owned
    CSTRING rdi, "_base_executable"
    mov rsi, [rbp - SME_STR]
    mov rdx, [rbp - SME_DICT]
    call sm_add_owned

    lea rdi, [rel pc_prefix]
    call str_from_cstr_heap
    mov [rbp - SME_STR], rax
    add qword [rax + PyObject.ob_refcnt], 3
    CSTRING rdi, "prefix"
    mov rsi, [rbp - SME_STR]
    mov rdx, [rbp - SME_DICT]
    call sm_add_owned
    CSTRING rdi, "exec_prefix"
    mov rsi, [rbp - SME_STR]
    mov rdx, [rbp - SME_DICT]
    call sm_add_owned
    CSTRING rdi, "base_prefix"
    mov rsi, [rbp - SME_STR]
    mov rdx, [rbp - SME_DICT]
    call sm_add_owned
    CSTRING rdi, "base_exec_prefix"
    mov rsi, [rbp - SME_STR]
    mov rdx, [rbp - SME_DICT]
    call sm_add_owned

    ; CPython's names the standard library, and platform reads it.
    lea rdi, [rel pc_stdlib]
    call str_from_cstr_heap
    mov rsi, rax
    CSTRING rdi, "_stdlib_dir"
    mov rdx, [rbp - SME_DICT]
    call sm_add_owned
    leave
    ret
END_FUNC sm_add_exe_paths

;; ============================================================================
;; sm_add_str(rdi = name cstr, rsi = value cstr, rdx = the module dict)
;;
;; One string attribute, interned from two C strings.  Open-coded it is
;; fifteen lines, and this file does it fifty-odd times; the prefix family is
;; where that started to hide which names were actually being set.
;; ============================================================================
;; SS_SET index, value -- fill one field of the structseq being built in rbx
;;
;; sys.flags and sys.float_info are assembled a field at a time, and the four
;; instructions that set one repeated forty-seven times.  The receiver is
;; always rbx and the index always the next integer, so the only thing worth
;; reading at a call site is which value goes where.
;;
;; `value` is a VALUE, not an integer: V_INT(n) for a literal, a register for
;; something computed.  Nothing generated here calls anything but
;; structseq_set, so rbx survives across the whole run.
;; ============================================================================
%macro SS_SET 2                 ; %1 = field index, %2 = the Value
    mov rdi, rbx
%if %1 == 0
    xor esi, esi
%else
    mov esi, %1
%endif
    mov rdx, %2
    call structseq_set
%endmacro

;; ============================================================================
SAS_DICT  equ 8
SAS_KEY   equ 16
SAS_FRAME equ 24            ; + 1 push = 32, 16-aligned
DEF_FUNC_LOCAL sm_add_str, SAS_FRAME
    push rbx
    mov [rbp - SAS_DICT], rdx
    mov rbx, rsi
    call str_from_cstr_heap             ; the key
    mov [rbp - SAS_KEY], rax
    mov rdi, rbx
    call str_from_cstr_heap             ; the value
    mov rbx, rax
    mov rdi, [rbp - SAS_DICT]
    mov rsi, [rbp - SAS_KEY]
    mov rdx, rax
    call dict_set                       ; takes its own reference to both
    mov rdi, rbx
    call obj_decref
    mov rdi, [rbp - SAS_KEY]
    call obj_decref
    pop rbx
    leave
    ret
END_FUNC sm_add_str

;; ============================================================================
;; sm_add_owned(rdi = name cstr, rsi = the object, OWNED, rdx = module dict)
;;   -> nothing; the dict holds the object and the caller's reference is gone
;;
;; The counterpart to sm_add_str for a value that is built rather than spelled:
;; a fresh list or dict.  Open-coding it cost eight pushes and two pads each
;; time, and path_importer_cache was written out that way before there were
;; three more of them.
;; ============================================================================
SAO_DICT  equ 8
SAO_VAL   equ 16
SAO_KEY   equ 24
SAO_FRAME equ 24            ; + 1 push = 32, 16-aligned
DEF_FUNC_LOCAL sm_add_owned, SAO_FRAME
    push rbx
    mov [rbp - SAO_DICT], rdx
    mov [rbp - SAO_VAL], rsi
    call str_from_cstr_heap             ; the key
    mov [rbp - SAO_KEY], rax
    mov rdi, [rbp - SAO_DICT]
    mov rsi, rax
    mov rdx, [rbp - SAO_VAL]
    call dict_set                       ; takes its own reference to both
    mov rdi, [rbp - SAO_VAL]
    call obj_decref
    mov rdi, [rbp - SAO_KEY]
    call obj_decref
    pop rbx
    leave
    ret
END_FUNC sm_add_owned

DEF_FUNC sys_module_init, 40
    push rbx
    push r12
    push r13
    push r14
    push r15

    mov [rbp - SMI_ARGC], rdi          ; argc
    mov [rbp - SMI_ARGV], rsi         ; argv

    ; Initialize int_max_str_digits to 4300 (CPython default)
    mov qword [rel sys_int_max_str_digits], 4300

    ; Create sys.modules dict
    call dict_new
    mov [rel sys_modules_dict], rax
    mov r14, rax                ; r14 = modules dict

    ; Create sys module dict
    call dict_new
    mov r15, rax                ; r15 = sys dict

    ; --- sys.modules ---
    lea rdi, [rel sm_modules]
    call str_from_cstr_heap
    push rax
    mov rdi, r15
    mov rsi, rax
    mov rdx, r14
    call dict_set
    pop rdi
    call obj_decref

    ; --- sys.path ---
    xor edi, edi                ; empty list
    call list_new
    mov [rel sys_path_list], rax
    mov r12, rax                ; r12 = sys.path list

    ; A placeholder for the script's directory, which main fills in once the
    ; script is known.  Under -P or -I there is none (sys.flags.safe_path).
    extern main_sysflags
    cmp byte [rel main_sysflags + SF_SAFE_PATH], 0
    jne .path_no_placeholder
    lea rdi, [rel sm_empty]
    call str_from_cstr_heap
    push rax
    mov rdi, r12
    mov rsi, rax
    call list_append
    pop rdi
    call obj_decref
.path_no_placeholder:

    ; Store sys.path
    lea rdi, [rel sm_path]
    call str_from_cstr_heap
    push rax
    mov rdi, r15
    mov rsi, rax
    mov rdx, r12
    call dict_set
    pop rdi
    call obj_decref
    mov rdi, r12            ; DECREF sys.path (dict_set INCREF'd)
    call obj_decref

    ; --- sys.argv ---
    xor edi, edi
    call list_new
    mov r13, rax                ; r13 = sys.argv list

    ; Populate sys.argv from process argv, starting at the *script*.  CPython's
    ; sys.argv[0] is the script, not the interpreter, so a script reading
    ; sys.argv[1] for its first argument was getting its own path.  main has
    ; already shifted argv past a -t if there was one, so index 1 is the script
    ; either way.
    mov rcx, [rbp - SMI_ARGC]         ; argc
    mov rdx, [rbp - SMI_ARGV]        ; argv
    mov ebx, 1                 ; i = 1: skip the interpreter
.argv_loop:
    cmp rbx, rcx
    jge .argv_done
    push rcx
    push rdx
    push rbx

    mov rdi, [rdx + rbx * 8]  ; argv[i]
    call str_from_cstr_heap
    push rax
    mov rdi, r13
    mov rsi, rax
    call list_append
    pop rdi
    call obj_decref

    pop rbx
    pop rdx
    pop rcx
    inc rbx
    jmp .argv_loop
.argv_done:

    lea rdi, [rel sm_argv]
    call str_from_cstr_heap
    push rax
    mov rdi, r15
    mov rsi, rax
    mov rdx, r13
    call dict_set
    pop rdi
    call obj_decref
    mov rdi, r13            ; DECREF sys.argv (dict_set INCREF'd)
    call obj_decref

    ; --- sys.orig_argv ---
    ; Every token the process was started with, interpreter and flags
    ; included, where sys.argv starts at the script.  CPython's is how a
    ; program re-execs itself with the same options, and platform and
    ; multiprocessing both read it.  main shifts argv past the flags it
    ; consumed, so this is what is LEFT of the original -- the honest answer
    ; from here, and enough for the re-exec it exists for.
    xor edi, edi
    call list_new
    mov r13, rax
    extern main_orig_argc
    extern main_orig_argv
    mov rcx, [rel main_orig_argc]
    mov rdx, [rel main_orig_argv]
    test rdx, rdx
    jz .oargv_done              ; not started from main: nothing to report
    xor ebx, ebx                ; from index 0: the interpreter itself
.oargv_loop:
    cmp rbx, rcx
    jge .oargv_done
    push rcx
    push rdx
    push rbx
    mov rdi, [rdx + rbx * 8]
    call str_from_cstr_heap
    push rax
    mov rdi, r13
    mov rsi, rax
    call list_append
    pop rdi
    call obj_decref
    pop rbx
    pop rdx
    pop rcx
    inc rbx
    jmp .oargv_loop
.oargv_done:
    lea rdi, [rel sm_orig_argv]
    mov rsi, r13
    mov rdx, r15
    call sm_add_owned

    ; --- sys.maxsize ---
    mov rdi, 0x7fffffffffffffff
    call int_from_i64
    push rdx                   ; save value tag
    push rax                   ; save value payload
    lea rdi, [rel sm_maxsize]
    call str_from_cstr_heap
    push rax
    mov rdi, r15
    mov rsi, rax               ; key = "maxsize" (str)
    mov rdx, [rsp + 8]        ; value payload
    mov ecx, [rsp + 16]       ; value tag (from int_from_i64)
    V_PACK rdx, rcx           ; dict_set takes Values
    call dict_set
    pop rdi
    call obj_decref            ; DECREF key string
    pop rdi                    ; value payload (SmallInt, no DECREF)
    pop rcx                    ; value tag (discard)

    ; --- sys.platform ---
    lea rdi, [rel sm_linux]
    call str_from_cstr_heap
    push rax
    lea rdi, [rel sm_platform]
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

    ; --- sys.version ---
    lea rdi, [rel sm_version_val]
    call str_from_cstr_heap
    push rax
    lea rdi, [rel sm_version]
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

    ; --- sys.version_info (a struct sequence) ---
    ; It was a bare tuple, so type(sys.version_info).__name__ was 'tuple' and
    ; sys.version_info.major was an AttributeError.  platform.py and several
    ; stdlib modules read the names.
    extern version_info_type
    extern float_info_type
    extern int_info_type
    extern hash_info_type
    extern thread_info_type
    extern float_info_v0
    extern float_info_v3
    extern float_info_v8
    extern hash_info_v5
    extern thread_info_v0
    extern structseq_new
    extern structseq_set
    extern structseq_init_type
    lea rdi, [rel version_info_type]
    call structseq_init_type
    ; sys.UnraisableHookArgs, which sys.unraisablehook is handed.  Only the
    ; type needs registering; the instances are built one at a time by the
    ; unraisable printer.
    extern unraisable_args_type
    lea rdi, [rel unraisable_args_type]
    call structseq_init_type
    ; sys.asyncgen_hooks, which get_asyncgen_hooks answers with.  Only the type
    ; is registered here; an instance is built per call.
    extern asyncgen_hooks_type
    lea rdi, [rel asyncgen_hooks_type]
    call structseq_init_type
    lea rdi, [rel version_info_type]
    call structseq_new
    mov rbx, rax                ; rbx = the version_info object

    ; (3, 12, 9, 'final', 0): the release the vendored stdlib/ is, and so
    ; the behaviour this interpreter answers for.  version and hexversion say
    ; the same; pyvenv.cfg and every version gate in the stdlib read them.
    SS_SET 0, V_INT(3)
    SS_SET 1, V_INT(12)
    SS_SET 2, V_INT(9)
    lea rdi, [rel sm_final]
    call str_from_cstr_heap
    mov rdx, rax                ; structseq_set takes over the reference
    mov rdi, rbx
    mov esi, 3
    call structseq_set
    mov rdi, rbx
    mov esi, 4
    xor edx, edx
    V_PACK_I64 rdx, rcx
    call structseq_set

    lea rdi, [rel sm_version_info]
    call str_from_cstr_heap
    push rax
    mov rdi, r15
    mov rsi, rax
    mov rdx, rbx
    call dict_set
    pop rdi
    call obj_decref
    mov rdi, rbx
    call obj_decref

    ; --- sys.executable, sys._base_executable, and the four prefix names ---
    ; All six come from /proc/self/exe.  base_prefix and base_exec_prefix are
    ; what a virtualenv leaves pointing at the installation it was made from;
    ; with no virtualenv all four name the same place.  CPython's getopt,
    ; gettext and optparse read the base_ pair unconditionally, so their
    ; absence was an AttributeError at import rather than anything the program
    ; could ask about.
    mov rdi, r15
    call sm_add_exe_paths

    ; --- sys.platlibdir ---
    ; The directory name a platform puts its libraries in: "lib" everywhere
    ; but the 64-bit RPM layouts, which use "lib64".  sysconfig reads it
    ; unconditionally while building _CONFIG_VARS, so without it pydoc, cgitb
    ; and everything downstream of them stopped at an AttributeError.
    lea rdi, [rel sm_platlibdir]
    lea rsi, [rel sm_lib]
    mov rdx, r15
    call sm_add_str

    ; --- sys.abiflags ---
    ; The suffix a CPython build puts on its library names -- "d" for a debug
    ; build, empty for an ordinary one.  sysconfig interpolates it into the
    ; name of the _sysconfigdata module it looks for, so its absence stopped
    ; the same imports platlibdir did, one line further on.
    lea rdi, [rel sm_abiflags]
    lea rsi, [rel sm_empty]
    mov rdx, r15
    call sm_add_str

    ; --- sys.copyright ---
    ; site.py reads it to build the `copyright` banner, unconditionally, so
    ; without it `import site` was an AttributeError.  Ours carries both
    ; notices: the interpreter is MIT, and the standard library it runs is
    ; the PSF's.
    lea rdi, [rel sm_copyright]
    lea rsi, [rel sm_copyright_text]
    mov rdx, r15
    call sm_add_str

    ; --- sys.stdout (fd=1) ---
    mov edi, 1
    lea rsi, [rel sm_stdout_name]
    lea rdx, [rel sm_mode_w]
    call fileobj_new
    mov [rel sys_stdout_obj], rax
    push rax
    lea rdi, [rel sm_stdout]
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

    ; sys.__stdout__ IS sys.stdout in CPython, and code checks the pair the way
    ; it checks sys.excepthook against sys.__excepthook__.
    SYS_ALIAS_SLOT sm_dunder_stdout, sys_stdout_obj

    ; --- sys.stderr (fd=2) ---
    mov edi, 2
    lea rsi, [rel sm_stderr_name]
    lea rdx, [rel sm_mode_w]
    call fileobj_new
    push rax
    lea rdi, [rel sm_stderr]
    call str_from_cstr_heap
    push rax
    mov rdi, r15
    mov rsi, rax
    mov rdx, [rsp + 8]
    call dict_set
    pop rdi
    call obj_decref
    ; the same object under its __ name, as CPython does
    lea rdi, [rel sm_dunder_stderr]
    call str_from_cstr_heap
    push rax
    push rax                    ; pad
    mov rdi, r15
    mov rsi, rax
    mov rdx, [rsp + 16]         ; the file object, still on the stack below
    call dict_set
    pop rdi
    pop rdi
    call obj_decref
    pop rdi
    call obj_decref

    ; --- sys.stdin (fd=0) ---
    xor edi, edi
    lea rsi, [rel sm_stdin_name]
    lea rdx, [rel sm_mode_r]
    call fileobj_new
    push rax
    lea rdi, [rel sm_stdin]
    call str_from_cstr_heap
    push rax
    mov rdi, r15
    mov rsi, rax
    mov rdx, [rsp + 8]
    call dict_set
    pop rdi
    call obj_decref
    ; the same object under its __ name, as CPython does
    lea rdi, [rel sm_dunder_stdin]
    call str_from_cstr_heap
    push rax
    push rax                    ; pad
    mov rdi, r15
    mov rsi, rax
    mov rdx, [rsp + 16]         ; the file object, still on the stack below
    call dict_set
    pop rdi
    pop rdi
    call obj_decref
    pop rdi
    call obj_decref

    ; --- sys.exit function ---
    lea rdi, [rel sys_exit_func]
    lea rsi, [rel sm_exit]
    call builtin_func_new
    push rax
    lea rdi, [rel sm_exit]
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

    ; --- sys.getrecursionlimit / sys.setrecursionlimit ---
    lea rdi, [rel sys_getrecursionlimit_func]
    lea rsi, [rel sm_getrecursionlimit]
    call builtin_func_new
    push rax
    lea rdi, [rel sm_getrecursionlimit]
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

    lea rdi, [rel sys_setrecursionlimit_func]
    lea rsi, [rel sm_setrecursionlimit]
    call builtin_func_new
    push rax
    lea rdi, [rel sm_setrecursionlimit]
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

    ; --- sys.implementation ---
    ; types.py takes SimpleNamespace from `type(sys.implementation)`, so this
    ; has to be a namespace rather than a tuple or a dict.  cache_tag is what
    ; a loader uses to NAME a .pyc, so it is this interpreter's own: apython
    ; reads CPython 3.12's caches as well, but it must not write under their
    ; name, or a python3 in the same tree picks up bytecode from our compiler.
    ; r14/r15 belong to the module dicts here, so the namespace lives in a
    ; frame slot.
    extern namespace_new
    extern namespace_set
    call namespace_new
    mov [rbp - SMI_TMP], rax

    lea rdi, [rel sm_apython_name]
    call str_from_cstr_heap
    push rax
    mov rdi, [rbp - SMI_TMP]
    lea rsi, [rel sm_name]
    mov rdx, rax
    call namespace_set
    pop rdi
    call obj_decref

    lea rdi, [rel sm_cache_tag_val]
    call str_from_cstr_heap
    push rax
    mov rdi, [rbp - SMI_TMP]
    lea rsi, [rel sm_cache_tag]
    mov rdx, rax
    call namespace_set
    pop rdi
    call obj_decref

    ; version comes back out of the sys dict rather than a stale register
    lea rdi, [rel sm_version_info]
    call str_from_cstr_heap
    push rax
    mov rdi, r15
    mov rsi, rax
    call dict_get
    V_UNPACK rax, rdx
    pop rdi
    push rax
    push rdx
    call obj_decref
    pop rdx
    pop rax
    test edx, edx
    jz .no_impl_version
    mov rdi, [rbp - SMI_TMP]
    lea rsi, [rel sm_version]
    mov rdx, rax
    call namespace_set
.no_impl_version:

    lea rdi, [rel sm_implementation]
    call str_from_cstr_heap
    push rax
    mov rdi, r15
    mov rsi, rax
    mov rdx, [rbp - SMI_TMP]
    call dict_set
    pop rdi
    call obj_decref
    mov rdi, [rbp - SMI_TMP]
    call obj_decref

    ; --- sys.warnoptions (empty; nothing parses -W yet) ---
    xor edi, edi
    call list_new
    mov [rbp - SMI_TMP], rax
    lea rdi, [rel sm_warnoptions]
    call str_from_cstr_heap
    push rax
    mov rdi, r15
    mov rsi, rax
    mov rdx, [rbp - SMI_TMP]
    call dict_set
    pop rdi
    call obj_decref
    mov rdi, [rbp - SMI_TMP]
    call obj_decref

    ; --- sys.builtin_module_names ---
    ; The modules that are compiled in rather than found on sys.path.  os.py
    ; reads it to decide which platform module to import, and several others
    ; use it to tell a built-in apart from a shadowing file.
    ; Built from builtin_module_table, the same rows import_init registers
    ; from.  It used to be a hand-written array here, and it had never grown
    ; `asyncio` or `errno` -- so a module sitting in sys.modules was absent
    ; from the list os.py gates its platform import on.
    ;
    ; The list also carries the modules this tree supplies from lib/ in place
    ; of a CPython builtin.  From a program's point of view they ARE built in
    ; -- the interpreter finds them with no path entry, and nothing on
    ; sys.path shadows one -- and CPython's own importlib._bootstrap tests
    ; this list by name before it will load `_thread` or `_warnings`, which
    ; is what twenty-one modules of its Lib/ stop at.
    extern builtin_module_table
    extern builtin_module_count
    mov rdi, [rel builtin_module_count]
    add rdi, SM_SUPPLIED_COUNT
    call tuple_new
    mov [rbp - SMI_TMP], rax
    xor r13d, r13d
.sm_bmn_loop:
    cmp r13, [rel builtin_module_count]
    jge .sm_bmn_supplied
    lea rax, [rel builtin_module_table]
    mov rcx, r13
    shl rcx, 4                              ; BuiltinModule_size
    mov rdi, [rax + rcx + BuiltinModule.name]
    call str_from_cstr_heap
    mov rcx, [rbp - SMI_TMP]
    mov rcx, [rcx + PyTupleObject.ob_item]  ; reload: the allocation moves it
    mov [rcx + r13*8], rax
    inc r13
    jmp .sm_bmn_loop
.sm_bmn_supplied:
    xor r12d, r12d
.sm_bmn_sup_loop:
    cmp r12, SM_SUPPLIED_COUNT
    jge .sm_bmn_done
    lea rax, [rel sm_supplied_names]
    mov rdi, [rax + r12*8]
    call str_from_cstr_heap
    mov rcx, [rbp - SMI_TMP]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov [rcx + r13*8], rax
    inc r13
    inc r12
    jmp .sm_bmn_sup_loop
.sm_bmn_done:
    ; CPython's is sorted, and a program may rely on that -- so the two
    ; tables are concatenated and then sorted, rather than each being kept in
    ; order against the other.
    mov rdi, [rbp - SMI_TMP]
    call sm_sort_names

    lea rdi, [rel sm_builtin_module_names]
    call str_from_cstr_heap
    push rax
    mov rdi, r15
    mov rsi, rax
    mov rdx, [rbp - SMI_TMP]
    call dict_set
    pop rdi
    call obj_decref
    mov rdi, [rbp - SMI_TMP]
    call obj_decref

    ; --- sys.byteorder ---
    lea rdi, [rel sm_little]
    call str_from_cstr_heap
    push rax
    lea rdi, [rel sm_byteorder]
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

    ; --- sys.flags ---
    extern flags_type
    lea rdi, [rel flags_type]
    call structseq_init_type
    lea rdi, [rel flags_type]
    call structseq_new
    mov rbx, rax
    ; Every field but the two bools and int_max_str_digits is a count main
    ; recorded while it read the command line.
    xor r12d, r12d
.flags_field:
    cmp r12d, SF_DEV_MODE
    je .flags_bool
    cmp r12d, SF_SAFE_PATH
    je .flags_bool
    lea rax, [rel main_sysflags]
    movzx edx, byte [rax + r12]
    V_PACK_I64 rdx, rax
    mov rdi, rbx
    mov esi, r12d
    call structseq_set
    jmp .flags_next
.flags_bool:
    lea rax, [rel main_sysflags]
    lea rdx, [rel bool_false]
    cmp byte [rax + r12], 0
    je .flags_have_bool
    lea rdx, [rel bool_true]
.flags_have_bool:
    inc qword [rdx + PyObject.ob_refcnt]
    mov rdi, rbx
    mov esi, r12d
    call structseq_set
.flags_next:
    inc r12d
    cmp r12d, SYSFLAGS_COUNT
    jb .flags_field
    SS_SET 17, V_INT(4300)
    lea rdi, [rel sm_flags]
    call str_from_cstr_heap
    push rax
    mov rdi, r15
    mov rsi, rax
    mov rdx, rbx
    call dict_set
    pop rdi
    call obj_decref
    mov rdi, rbx
    call obj_decref
    ; --- sys.float_info ---
    lea rdi, [rel float_info_type]
    call structseq_init_type
    lea rdi, [rel float_info_type]
    call structseq_new
    mov rbx, rax
    mov rdi, rbx
    xor esi, esi
    mov rdx, [rel float_info_v0]
    V_FROM_F64 rdx, rcx
    call structseq_set
    SS_SET 1, V_INT(1024)
    SS_SET 2, V_INT(308)
    mov rdi, rbx
    mov esi, 3
    mov rdx, [rel float_info_v3]
    V_FROM_F64 rdx, rcx
    call structseq_set
    SS_SET 4, V_INT(-1021)
    SS_SET 5, V_INT(-307)
    SS_SET 6, V_INT(15)
    SS_SET 7, V_INT(53)
    mov rdi, rbx
    mov esi, 8
    mov rdx, [rel float_info_v8]
    V_FROM_F64 rdx, rcx
    call structseq_set
    SS_SET 9, V_INT(2)
    SS_SET 10, V_INT(1)
    lea rdi, [rel sm_float_info]
    call str_from_cstr_heap
    push rax
    mov rdi, r15
    mov rsi, rax
    mov rdx, rbx
    call dict_set
    pop rdi
    call obj_decref
    mov rdi, rbx
    call obj_decref

    ; --- sys.int_info ---
    ; GMP-backed ints have no fixed digit size; these are CPython's
    ; numbers, which is what the modules reading them expect.
    lea rdi, [rel int_info_type]
    call structseq_init_type
    lea rdi, [rel int_info_type]
    call structseq_new
    mov rbx, rax
    SS_SET 0, V_INT(30)
    SS_SET 1, V_INT(4)
    SS_SET 2, V_INT(4300)
    SS_SET 3, V_INT(640)
    lea rdi, [rel sm_int_info]
    call str_from_cstr_heap
    push rax
    mov rdi, r15
    mov rsi, rax
    mov rdx, rbx
    call dict_set
    pop rdi
    call obj_decref
    mov rdi, rbx
    call obj_decref

    ; --- sys.hash_info ---
    ; modulus and imag are ours for real -- int_hash_i64 uses 2^61-1
    ; and complex_hash 1000003.  algorithm says 'fnv' because
    ; str_hash is FNV-1a, not siphash; seed_bits and cutoff are 0
    ; because there is no hash randomisation to describe.
    lea rdi, [rel hash_info_type]
    call structseq_init_type
    lea rdi, [rel hash_info_type]
    call structseq_new
    mov rbx, rax
    SS_SET 0, V_INT(64)
    mov rdi, rbx
    mov esi, 1
    mov rdx, 2305843009213693951
    V_PACK_I64 rdx, rcx
    call structseq_set
    SS_SET 2, V_INT(314159)
    SS_SET 3, V_INT(0)
    SS_SET 4, V_INT(1000003)
    mov rdi, rbx
    mov esi, 5
    lea rdi, [rel hash_info_v5]
    call str_from_cstr_heap
    mov rdx, rax
    mov rdi, rbx
    mov esi, 5
    call structseq_set
    SS_SET 6, V_INT(64)
    SS_SET 7, V_INT(0)
    SS_SET 8, V_INT(0)
    lea rdi, [rel sm_hash_info]
    call str_from_cstr_heap
    push rax
    mov rdi, r15
    mov rsi, rax
    mov rdx, rbx
    call dict_set
    pop rdi
    call obj_decref
    mov rdi, rbx
    call obj_decref

    ; --- sys.thread_info ---
    ; Three fields, and the name is the honest one: `pthread-stubs` is what
    ; CPython reports for a build whose threads do not start, which is what
    ; lib/_thread.py is.  lock and version are None because there is nothing
    ; to name, which is also how CPython leaves them when it cannot tell --
    ; and it is what makes `if sys.thread_info.version:` guards skip.
    lea rdi, [rel thread_info_type]
    call structseq_init_type
    lea rdi, [rel thread_info_type]
    call structseq_new
    mov rbx, rax
    lea rdi, [rel thread_info_v0]
    call str_from_cstr_heap
    mov rdx, rax
    mov rdi, rbx
    xor esi, esi
    call structseq_set
    ; structseq_set takes over the caller's reference, so None needs one each.
    lea rdx, [rel none_singleton]
    inc qword [rdx + PyObject.ob_refcnt]
    mov rdi, rbx
    mov esi, 1
    call structseq_set
    lea rdx, [rel none_singleton]
    inc qword [rdx + PyObject.ob_refcnt]
    mov rdi, rbx
    mov esi, 2
    call structseq_set
    lea rdi, [rel sm_thread_info]
    call str_from_cstr_heap
    push rax
    mov rdi, r15
    mov rsi, rax
    mov rdx, rbx
    call dict_set
    pop rdi
    call obj_decref
    mov rdi, rbx
    call obj_decref

    ; --- sys.getdefaultencoding function ---
    lea rdi, [rel sys_getdefaultencoding_func]
    lea rsi, [rel sm_getdefaultencoding]
    call builtin_func_new
    push rax
    lea rdi, [rel sm_getdefaultencoding]
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

    ; --- sys.getfilesystemencoding function ---
    ; os._createenviron decodes posix.environ with it.  It answers 'utf-8'
    ; unconditionally: PEP 540's locale handling does not exist here, and
    ; neither does the surrogateescape error handler that would make a
    ; non-UTF-8 filename survive the round trip -- bugs.md records the gap.
    lea rdi, [rel sys_getfsencoding_func]
    lea rsi, [rel sm_getfsencoding]
    call builtin_func_new
    push rax
    lea rdi, [rel sm_getfsencoding]
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

    ; --- sys.getfilesystemencodeerrors function ---
    ; os._fscodec reads it next to getfilesystemencoding.  It answers
    ; 'surrogateescape', which is the name CPython uses -- and which
    ; str.encode here accepts and ignores; bugs.md records that.
    lea rdi, [rel sys_getfsencodeerrors_func]
    lea rsi, [rel sm_getfsencodeerrors]
    call builtin_func_new
    push rax
    lea rdi, [rel sm_getfsencodeerrors]
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

    ; --- sys.excepthook / sys.__excepthook__ / sys.unraisablehook ---
    ;
    ; threading reads sys.excepthook at import time, to save and restore it
    ; around a thread's run().  It is the same report the interpreter prints
    ; for an uncaught exception, which traceback_print already produces.
    SYS_ADD_FUNC_ALIAS sys_excepthook_func, sm_excepthook, sm_dunder_excepthook
    SYS_ADD_FUNC_ALIAS sys_displayhook_func, sm_displayhook, sm_dunder_displayhook
    SYS_ADD_FUNC sys_getrefcount_func, sm_getrefcount
    SYS_ADD_FUNC sys_is_finalizing_func, sm_is_finalizing
    SYS_ADD_FUNC_ALIAS sys_unraisablehook_func, sm_unraisablehook, \
                       sm_dunder_unraisablehook
    SYS_ADD_FUNC sys_get_asyncgen_hooks_func, sm_get_asyncgen_hooks
    SYS_ADD_FUNC sys_set_asyncgen_hooks_func, sm_set_asyncgen_hooks
    SYS_ADD_FUNC sys_exc_info_func, sm_exc_info
    SYS_ADD_FUNC sys_exception_func, sm_exception

    ; Constants CPython has had since 2.x and code reads without asking.
    ; hexversion is the one a version test is usually written against.
    SYS_ADD_INT sm_hexversion, 0x030C09F0
    SYS_ADD_INT sm_maxunicode, 0x10FFFF
    ; "short" is true: src/dtoa.asm computes the shortest round-tripping
    ; decimal rather than searching for it.
    lea rdi, [rel sm_float_repr_style]
    lea rsi, [rel sm_short]
    mov rdx, r15
    call sm_add_str
    ; import.asm caches what it compiles, so this is a switch now rather than
    ; a fact.  -B is the initial value; a program may set it either way, and
    ; pyc_write_cache reads it back on every write.
    extern main_no_bytecode
    cmp byte [rel main_no_bytecode], 0
    jne .sm_no_bytecode
    SYS_ADD_OBJ sm_dont_write_bytecode, bool_false
    jmp .sm_bytecode_done
.sm_no_bytecode:
    SYS_ADD_OBJ sm_dont_write_bytecode, bool_true
.sm_bytecode_done:
    ; None, and importlib._bootstrap_external reads it on every path it
    ; caches -- unguarded, so its absence stopped importlib installing its
    ; own finders and left sys.meta_path empty.
    SYS_ADD_OBJ sm_pycache_prefix, none_singleton
    ; The import machinery's own three attributes, all empty.  The finders here
    ; are assembly rather than importlib path hooks, so nothing will ever
    ; populate them -- but importlib._bootstrap walks meta_path on EVERY import
    ; and path_hooks whenever a path entry has no finder cached, and neither
    ; read is guarded, so their absence was an AttributeError raised from
    ; inside `import`.  Measured over CPython 3.12's own Lib/test, that was the
    ; single most common way a module failed.
    call dict_new
    lea rdi, [rel sm_path_importer_cache]
    mov rsi, rax
    mov rdx, r15
    call sm_add_owned
    xor edi, edi
    call list_new
    lea rdi, [rel sm_meta_path]
    mov rsi, rax
    mov rdx, r15
    call sm_add_owned
    xor edi, edi
    call list_new
    lea rdi, [rel sm_path_hooks]
    mov rsi, rax
    mov rdx, r15
    call sm_add_owned
    ; audit() and addaudithook() do nothing: there are no audit hooks here,
    ; and with none installed CPython's audit() is a no-op too.  os.walk,
    ; os.listdir and half of shutil call audit() unconditionally, and an
    ; AttributeError from it stopped them.
    SYS_ADD_FUNC sys_audit_func, sm_audit
    SYS_ADD_FUNC sys_audit_func, sm_addaudithook

    ; --- sys._getframe / sys._getframemodulename ---
    ;
    ; warnings._deprecated reaches for both, and nine stdlib modules come in
    ; behind that one call.  What comes back is a live VIEW onto the frame,
    ; and the same object each time it is asked -- see src/pyo/frameobj.asm.
    extern sys_getframe_func
    extern sys_getframemodulename_func
    SYS_ADD_FUNC sys_getframe_func, sm_getframe
    SYS_ADD_FUNC sys_getframemodulename_func, sm_getframemodulename
    SYS_ADD_FUNC sys_getsizeof_func, sm_getsizeof
    SYS_ADD_FUNC sys_clear_type_cache_func, sm_clear_type_cache
    extern sys_current_frames_func
    SYS_ADD_FUNC sys_current_frames_func, sm_current_frames
    ; breakpointhook and __breakpointhook__ are ONE object, as excepthook and
    ; __excepthook__ are: `sys.breakpointhook is sys.__breakpointhook__` is
    ; how a program asks whether a debugger has replaced it.
    SYS_ADD_FUNC_ALIAS sys_breakpointhook_func, sm_breakpointhook, \
                       sm_dunder_breakpointhook

    ; --- the tracing hooks ---
    ;
    ; bdb, pdb, trace and profile are written against these five and nothing
    ; else.  What they cost when nothing is set is nothing: see
    ; src/systrace.asm.
    extern sys_settrace_func
    extern sys_gettrace_func
    extern sys_setprofile_func
    extern sys_getprofile_func
    extern sys_call_tracing_func
    SYS_ADD_FUNC sys_settrace_func, sm_settrace
    SYS_ADD_FUNC sys_gettrace_func, sm_gettrace
    SYS_ADD_FUNC sys_setprofile_func, sm_setprofile
    SYS_ADD_FUNC sys_getprofile_func, sm_getprofile
    SYS_ADD_FUNC sys_call_tracing_func, sm_call_tracing

    ; --- sys.intern function ---
    lea rdi, [rel sys_intern_func]
    lea rsi, [rel sm_intern]
    call builtin_func_new
    push rax
    lea rdi, [rel sm_intern]
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

    ; --- sys.get_int_max_str_digits function ---
    lea rdi, [rel sys_get_int_max_str_digits_func]
    lea rsi, [rel sm_get_int_max_str_digits]
    call builtin_func_new
    push rax
    lea rdi, [rel sm_get_int_max_str_digits]
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

    ; --- sys.set_int_max_str_digits function ---
    lea rdi, [rel sys_set_int_max_str_digits_func]
    lea rsi, [rel sm_set_int_max_str_digits]
    call builtin_func_new
    push rax
    lea rdi, [rel sm_set_int_max_str_digits]
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

    ; --- sys.get/set_coroutine_origin_tracking_depth ---
    SYS_ADD_FUNC sys_get_coroutine_origin_tracking_depth_func, \
                 sm_get_coroutine_origin_tracking_depth
    SYS_ADD_FUNC sys_set_coroutine_origin_tracking_depth_func, \
                 sm_set_coroutine_origin_tracking_depth

    ; --- the attributes a program asks for by name -----------------------
    ;
    ; None of these is decoration.  test.support and regrtest read _xoptions
    ; and _git on the way in, so their absence stopped fifty-five and
    ; twenty-seven of CPython's tests before any of them ran; api_version,
    ; orig_argv and _stdlib_dir are read by platform, and __spec__,
    ; __loader__ and __package__ are what every module HAS -- sys is built by
    ; hand here and never goes through import_load_module, which is the only
    ; reason it had none.
    SYS_ADD_INT sm_api_version, 1013

    ; -X options: an empty dict, and it has to BE a dict.  test.support does
    ; `sys._xoptions.get(...)`, and absent is an AttributeError a dozen
    ; modules do not survive.
    call dict_new
    lea rdi, [rel sm_xoptions]
    mov rsi, rax
    mov rdx, r15
    call sm_add_owned

    ; sys._git is (implementation, branch, revision).  CPython's carries its
    ; own repository's; this names itself and leaves the other two empty,
    ; which is the shape and the only honest content.
    mov edi, 3
    call tuple_new
    push rax
    lea rdi, [rel sm_apython]
    call str_from_cstr_heap
    mov rcx, [rsp]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov [rcx], rax
    lea rdi, [rel sm_empty]
    call str_from_cstr_heap
    mov rcx, [rsp]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov [rcx + 8], rax
    lea rdi, [rel sm_empty]
    call str_from_cstr_heap
    mov rcx, [rsp]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov [rcx + 16], rax
    pop rsi
    lea rdi, [rel sm_git]
    mov rdx, r15
    call sm_add_owned

    ; The three every module has.  __spec__ is None here for the same reason
    ; it is None on an imported module -- nothing builds a ModuleSpec, which
    ; bugs.md records -- and __package__ is "" for a top-level module.
    SYS_ADD_OBJ sm_dunder_spec, none_singleton
    SYS_ADD_OBJ sm_dunder_loader, none_singleton
    lea rdi, [rel sm_dunder_package]
    lea rsi, [rel sm_empty]
    mov rdx, r15
    call sm_add_str

    ; sys.stdlib_module_names is deliberately NOT here.  It is a frozenset
    ; whose whole use is membership -- code asks whether a name is the
    ; standard library's -- and the only set this tree can build honestly is
    ; the builtin modules plus lib/'s C stand-ins.  `"os" in
    ; sys.stdlib_module_names` would then be False, which is a wrong answer
    ; where an AttributeError is merely a missing one; that is the
    ; half-implemented-is-worse shape.  A complete list means a generated
    ; table of what lib/ ships, which is `make regen` work.

    ; --- Create the sys module object ---
    lea rdi, [rel sm_sys]
    call str_from_cstr_heap
    mov rdi, rax
    mov rsi, r15                ; dict
    call module_new
    mov [rel sys_module_obj], rax

    ; Register sys in sys.modules
    lea rdi, [rel sm_sys]
    call str_from_cstr_heap
    push rax
    mov rdi, r14                ; sys.modules dict
    mov rsi, rax
    mov rdx, [rel sys_module_obj]
    call dict_set
    pop rdi
    call obj_decref

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC sys_module_init

;; ============================================================================
;; sys.getsizeof(o[, default]) -> int
;;
;; CPython calls type(o).__sizeof__(o), so a type that overrides it is
;; honoured; this does the same, through dunder_call_1.
;; test.support.check_sizeof is written on it and
;; lib/_testinternalcapi.py's SIZEOF_PYGC_HEAD is added to what it answers,
;; so its absence stopped a dozen of CPython's test modules before their
;; first test.
;;
;; object.__sizeof__ answers tp_basicsize and nothing more.  CPython adds
;; ob_size * tp_itemsize for a variable-size type, and there is no
;; tp_itemsize in this tree's PyTypeObject -- the types that carry their data
;; inline each know their own stride and nothing central records it -- so a
;; str, a tuple and a bytes all report the header alone.  DIVERGENCES.md
;; records it; what reads this wants an int, and one that a type can override.
;;
;; The default argument is reached only when there is no __sizeof__ at all,
;; which is what CPython uses it for too.
;; ============================================================================
SGS_ARGS  equ 8
SGS_NARGS equ 16
SGS_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
DEF_FUNC sys_getsizeof_func, SGS_FRAME
    test rsi, rsi
    jz .sgs_args
    mov [rbp - SGS_ARGS], rdi
    mov [rbp - SGS_NARGS], rsi
    mov rdi, [rdi]              ; args[0], as a Value
    ; dunder_call_1 takes a POINTER.  An immediate is its own Value and has no
    ; object to look a dunder up on, so its own type answers for it: the size
    ; of the PyIntObject or PyFloatObject it would have needed on the heap.
    V_TEST_PTR rdi, rcx
    ja .sgs_immediate
    test rdi, rdi
    jz .sgs_immediate
    CSTRING rsi, "__sizeof__"
    call dunder_call_1
    test rax, rax
    jz .sgs_no_sizeof
    ; CPython adds the collector's header when the object is tracked, and
    ; test.support.check_sizeof adds it back on the other side -- so the
    ; relationship between getsizeof and __sizeof__ has to hold even where
    ; the absolute numbers cannot.
    mov rdi, [rbp - SGS_ARGS]
    mov rdi, [rdi]
    V_TEST_PTR rdi, rcx
    ja .sgs_ret
    test rdi, rdi
    jz .sgs_ret
    mov rcx, [rdi + PyObject.ob_type]
    test qword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_HAVE_GC
    jz .sgs_ret
    push rax
    mov rdi, rax
    V_UNPACK rdi, rdx
    extern int_to_i64
    call int_to_i64
    add rax, GC_HEAD_SIZE
    mov rdi, rax
    call int_from_i64
    V_PACK rax, rdx
    mov [rsp], rax
    pop rax
.sgs_ret:
    leave
    ret                         ; already a Value
.sgs_immediate:
    mov rdi, [rbp - SGS_ARGS]
    mov rdi, [rdi]
    extern value_type
    call value_type
    test rax, rax
    jz .sgs_no_sizeof
    mov rdi, [rax + PyTypeObject.tp_basicsize]
    call int_from_i64
    leave
    V_PACK rax, rdx
    ret

.sgs_no_sizeof:
    ; Absent, not callable, or it raised.  A default was given, or this is
    ; the TypeError CPython gives.
    cmp qword [rbp - SGS_NARGS], 2
    jl .sgs_no_default
    mov qword [gs:ThreadState.current_exception], 0
    mov rdi, [rbp - SGS_ARGS]
    mov rax, [rdi + 8]
    INCREF_V rax, rdx
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
.sgs_no_default:
    RAISE exc_TypeError_type, "getsizeof() argument has no __sizeof__"
.sgs_args:
    RAISE exc_TypeError_type, "getsizeof() takes at least 1 argument"
END_FUNC sys_getsizeof_func

;; ============================================================================
;; sys._clear_type_cache() -> None
;;
;; The method cache is an invisible optimisation, and a test that changes a
;; class and asks whether the change took effect has to be able to empty it.
;; test_type_cache and test_descr both call this.
;; ============================================================================
DEF_FUNC sys_clear_type_cache_func
    extern type_cache_clear
    call type_cache_clear
    lea rax, [rel none_singleton]
    INCREF rax
    mov edx, TAG_PTR
    leave
    ret
END_FUNC sys_clear_type_cache_func

;; ============================================================================
;; sys.breakpointhook(*args, **kwargs) -> whatever pdb.set_trace answers
;;
;; What breakpoint() calls.  CPython's default reads $PYTHONBREAKPOINT, and
;; imports and calls whatever it names; the built-in default is
;; pdb.set_trace.  The environment variable is not honoured here -- that is
;; an import of an arbitrary dotted name -- and "0" is not either; what is
;; honoured is the hook being REPLACEABLE, which is what a debugger and every
;; test of one actually use.
;;
;; builtin_breakpoint used to be a no-op, so breakpoint() silently did
;; nothing at all.
;; ============================================================================
DEF_FUNC sys_breakpointhook_func
    extern import_module
    extern str_from_cstr_heap
    CSTRING rdi, "pdb"
    call str_from_cstr_heap
    test rax, rax
    jz .sbh_none
    mov rdi, rax
    push rdi
    xor esi, esi
    xor edx, edx
    call import_module
    pop rdi
    push rax
    call obj_decref
    pop rax
    test rax, rax
    jz .sbh_none
    push rax
    CSTRING rdi, "set_trace"
    call str_from_cstr_heap
    mov rsi, rax
    mov rdi, [rsp]
    push rsi
    call obj_getattr_opt
    pop rdi
    push rax
    call obj_decref
    pop rax
    pop rdi                     ; the module
    push rax
    call obj_decref
    pop rax
    test rax, rax
    jz .sbh_none
    mov rdi, rax
    push rdi
    xor esi, esi
    xor edx, edx
    call obj_call_n
    pop rdi
    push rax
    call obj_decref
    pop rax
    test rax, rax
    jz .sbh_raised
    leave
    ret
.sbh_raised:
    xor eax, eax
    xor edx, edx
    leave
    ret
.sbh_none:
    ; No pdb, or it would not import.  Answer None rather than raising: a
    ; breakpoint() in a program with no debugger available should not stop it.
    mov qword [gs:ThreadState.current_exception], 0
    lea rax, [rel none_singleton]
    INCREF rax
    mov edx, TAG_PTR
    leave
    ret
END_FUNC sys_breakpointhook_func

;; ============================================================================
;; sys.getrecursionlimit() / sys.setrecursionlimit(n)
;; The interpreter has had a recursion counter since the bare SIGSEGV was
;; replaced with a RecursionError; these expose the limit it checks.
;; ============================================================================
DEF_FUNC sys_getrecursionlimit_func
    mov rax, [rel recursion_limit]
    extern recursion_limit
    mov edx, TAG_SMALLINT
    leave
    V_PACK rax, rdx
    ret
END_FUNC sys_getrecursionlimit_func

DEF_FUNC sys_setrecursionlimit_func
    cmp rsi, 1
    jne .srl_error
    mov rdi, [rdi]
    V_UNPACK rdi, rdx
    extern int_is_integer
    push rdi
    push rdx
    call int_is_integer
    pop rdx
    pop rdi
    test eax, eax
    jz .srl_error
    extern int_to_i64
    call int_to_i64
    cmp rax, 1
    jl .srl_value_error
    mov [rel recursion_limit], rax
    RET_NONE
    leave
    V_PACK rax, rdx
    ret
.srl_error:
    RAISE exc_TypeError_type, "setrecursionlimit() argument must be an int"
.srl_value_error:
    extern exc_ValueError_type
    RAISE exc_ValueError_type, "recursion limit must be greater or equal than 1"
END_FUNC sys_setrecursionlimit_func

;; ============================================================================
;; sys_exit_func(PyObject **args, int64_t nargs) -> PyObject*
;; sys.exit([code]) — exit the process
;; ============================================================================
DEF_FUNC sys_exit_func
    ; sys.exit raises SystemExit; it does not call the exit syscall.  Calling
    ; it directly skipped every `finally` block and context-manager __exit__
    ; between here and the top, and made `except SystemExit` unwritable.
    ; main.asm turns an uncaught SystemExit into the process status.
    xor edx, edx                ; no argument -> SystemExit()
    cmp rsi, 1
    jne .se_raise
    mov rdx, [rdi]              ; args[0], already a Value
    lea rax, [rel none_singleton]
    cmp rdx, rax
    jne .se_raise
    xor edx, edx                ; sys.exit(None) is SystemExit(None) -> args ()
.se_raise:
    mov rsi, rdx
    lea rdi, [rel exc_SystemExit_type]
    xor edx, edx
    extern exc_SystemExit_type
    extern exc_new
    call exc_new
    mov rdi, rax
    extern raise_exception_obj
    call raise_exception_obj
    ud2
END_FUNC sys_exit_func

;; ============================================================================
;; sys_getdefaultencoding_func(PyObject **args, int64_t nargs) -> rax = Value
;; Returns "utf-8"
;; ============================================================================
DEF_FUNC sys_getdefaultencoding_func
    lea rdi, [rel sm_utf8]
    call str_from_cstr_heap
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC sys_getdefaultencoding_func

;; ============================================================================
;; sys_get_int_max_str_digits_func(PyObject **args, int64_t nargs) -> rax = Value
;; Returns the current int max str digits limit
;; ============================================================================
DEF_FUNC sys_get_int_max_str_digits_func
    test rsi, rsi
    jne .get_imsd_error
    mov rdi, [rel sys_int_max_str_digits]
    call int_from_i64
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
.get_imsd_error:
    extern exc_TypeError_type
    RAISE exc_TypeError_type, "get_int_max_str_digits() takes no arguments"
END_FUNC sys_get_int_max_str_digits_func

;; ============================================================================
;; sys_set_int_max_str_digits_func(PyObject **args, int64_t nargs) -> rax = Value
;; Sets the int max str digits limit. 0 = unlimited, otherwise >= 640
;; ============================================================================
DEF_FUNC sys_set_int_max_str_digits_func
    cmp rsi, 1
    jne .set_imsd_error

    mov rdi, [rdi]            ; args[0]

    V_UNPACK rdi, rdx
    call int_to_i64
    ; rax = new limit
    test rax, rax
    jz .set_imsd_ok         ; 0 = unlimited
    cmp rax, 640
    jl .set_imsd_value_error

.set_imsd_ok:
    mov [rel sys_int_max_str_digits], rax
    RET_NONE
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.set_imsd_value_error:
    extern exc_ValueError_type
    RAISE exc_ValueError_type, "set_int_max_str_digits: value must be 0 or >= 640"

.set_imsd_error:
    RAISE exc_TypeError_type, "set_int_max_str_digits() takes exactly 1 argument"
END_FUNC sys_set_int_max_str_digits_func

;; ============================================================================
;; sys_get_coroutine_origin_tracking_depth_func(args, nargs) -> rax = Value
;;
;; -> the depth last set, as an int.  Zero until something sets it.
;;
;; asyncio's BaseEventLoop._set_coroutine_origin_tracking calls this on every
;; run_forever, so its absence was not a missing introspection knob: it was
;; every IsolatedAsyncioTestCase in the standard library dying before its
;; first await, which is the whole of test_unittest and test_inspect and most
;; of test_os.
;; ============================================================================
DEF_FUNC sys_get_coroutine_origin_tracking_depth_func
    test rsi, rsi
    jne .get_codt_error
    mov rdi, [gs:ThreadState.coroutine_origin_depth]
    call int_from_i64
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
.get_codt_error:
    extern exc_TypeError_type
    RAISE exc_TypeError_type, \
          "get_coroutine_origin_tracking_depth() takes no arguments"
END_FUNC sys_get_coroutine_origin_tracking_depth_func

;; ============================================================================
;; sys_set_coroutine_origin_tracking_depth_func(args, nargs) -> rax = Value
;;
;; -> None.  Refuses a negative depth, as CPython's does.
;;
;; obj_as_index and not int_to_i64: that one reads PyIntObject.compact off
;; whatever it is handed, so a float or a list was a dereference of the number
;; and `set_coroutine_origin_tracking_depth("hello")` stored a str's ob_size.
;; asyncio's _set_coroutine_origin_tracking forwards whatever it is given.
;; ============================================================================
DEF_FUNC sys_set_coroutine_origin_tracking_depth_func
    cmp rsi, 1
    jne .set_codt_error

    mov rdi, [rdi]              ; args[0]
    V_UNPACK rdi, rdx
    extern obj_as_index
    call obj_as_index           ; names the type for anything else
    test rax, rax
    js .set_codt_value_error

    mov [gs:ThreadState.coroutine_origin_depth], rax
    RET_NONE
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.set_codt_value_error:
    extern exc_ValueError_type
    RAISE exc_ValueError_type, "depth must be >= 0"

.set_codt_error:
    RAISE exc_TypeError_type, \
          "set_coroutine_origin_tracking_depth() takes exactly 1 argument"
END_FUNC sys_set_coroutine_origin_tracking_depth_func

;; ============================================================================
;; sys_path_add_script_dir(const char *pyc_path)
;; Extract directory from the .pyc path and prepend to sys.path[0]
;; ============================================================================
DEF_FUNC sys_path_add_script_dir
    push rbx
    push r12

    mov rbx, rdi                ; pyc_path

    ; -P and -I: sys.path gets no entry for the script at all.
    cmp byte [rel main_sysflags + SF_SAFE_PATH], 0
    jne .spa_out
    ; An empty path is -c or stdin, whose entry CPython leaves as ''.
    cmp byte [rbx], 0
    jne .find_last
    lea rdi, [rel sm_empty]
    call str_from_cstr_heap
    jmp .set_path

.find_last:
    ; Find last '/' in path
    mov rdi, rbx
    call ap_strlen
    mov r12, rax                ; length
    mov rcx, rax

.find_slash:
    dec rcx
    js .use_dot                 ; no slash found, use "."
    cmp byte [rbx + rcx], '/'
    jne .find_slash

    ; Found slash at position rcx
    ; Create string from path[0..rcx] (the directory part)
    test rcx, rcx
    jz .use_root                ; path starts with /, use "/"

    ; Create substring
    lea rdi, [rbx]
    mov rsi, rcx                ; length (excludes the slash)
    call str_new
    jmp .set_path

.use_root:
    lea rdi, [rel sm_slash]
    call str_from_cstr_heap
    jmp .set_path

.use_dot:
    lea rdi, [rel sm_dot]
    call str_from_cstr_heap

.set_path:
    ; Replace sys.path[0] with this directory
    ; rax = payload, rdx = tag (TAG_PTR)
    push rdx                    ; save new path tag
    push rax                    ; save new path payload
    mov rdi, [rel sys_path_list]
    ; Set list item 0
    mov rcx, [rdi + PyListObject.ob_item]       ; payloads
    ; DECREF old item[0]
    mov rdi, [rcx]
    DECREF_V rdi, rsi
    pop rax                     ; restore new path payload
    pop rdx                     ; restore new path tag
    V_PACK rax, rdx
    mov rdi, [rel sys_path_list]
    mov rcx, [rdi + PyListObject.ob_item]
    mov [rcx], rax

.spa_out:
    pop r12
    pop rbx
    leave
    ret
END_FUNC sys_path_add_script_dir

;; ============================================================================
;; Data
;; ============================================================================

;; ============================================================================
;; sys.intern(string) -> string
;;
;; A real intern table, so `sys.intern(a) is sys.intern(b)` for equal strings.
;; functools and enum both intern names and then compare them with `is`.
;; ============================================================================
;; sys.getfilesystemencodeerrors() -> 'surrogateescape'
DEF_FUNC sys_getfsencodeerrors_func
    lea rdi, [rel sm_surrogateescape]
    call str_from_cstr_heap
    leave
    mov edx, TAG_PTR
    V_PACK rax, rdx
    ret
END_FUNC sys_getfsencodeerrors_func

;; sys.audit(event, *args) / sys.addaudithook(hook) -> None
;;
;; No hooks, so nothing to run.  Both are here because the stdlib calls
;; audit() on the way into any number of ordinary operations and does not
;; guard it.
;; ============================================================================
DEF_FUNC sys_audit_func
    LOAD_NONE rax
    leave
    ret
END_FUNC sys_audit_func

;; ============================================================================
;; sys.getfilesystemencoding() -> 'utf-8'
DEF_FUNC sys_getfsencoding_func
    lea rdi, [rel sm_utf8]
    call str_from_cstr_heap
    leave
    mov edx, TAG_PTR
    V_PACK rax, rdx
    ret
END_FUNC sys_getfsencoding_func

DEF_FUNC sys_intern_func
    cmp rsi, 1
    jne .si_error               ; exactly one argument, as CPython requires
    push rbx
    mov rbx, [rdi]
    V_TEST_PTR rbx, rax
    ja .si_not_str
    test rbx, rbx
    jz .si_not_str
    mov rax, [rbx + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    jne .si_not_str

    ; The one table, the same one marshal and the compiler file names in.
    ; This used to be a private dict of its own, so `sys.intern('foo') is
    ; 'foo'` was False here and True in CPython -- and functools and enum
    ; intern names and then compare them with `is`, so every such comparison
    ; was False.
    mov rdi, rbx
    call str_intern
    pop rbx
    leave
    V_PACK rax, rdx
    ret
.si_not_str:
    mov rsi, rbx
    pop rbx
    extern raise_type_error_with_name
    CSTRING rdi, `intern() argument must be str, not \x01`
    call raise_type_error_with_name
.si_error:
    RAISE exc_TypeError_type, "sys.intern() takes exactly one argument"
END_FUNC sys_intern_func

section .rodata

seh_not_exc_msg:
    db "TypeError: print_exception(): Exception expected for value, ", 0
seh_not_exc_end: db " found", 10, 0
sm_sys:          db "sys", 0
sm_modules:      db "modules", 0
sm_path:         db "path", 0
sm_argv:         db "argv", 0
sm_maxsize:      db "maxsize", 0
sm_platform:     db "platform", 0
sm_linux:        db "linux", 0
sm_version:      db "version", 0
; platform._sys_version's regex ends in `\[([^\]]+)\]?`, so a BRACKETED
; compiler field is not optional: without it every call into `platform` raised
; "failed to parse CPython sys.version".  The name a program should read for
; the implementation is sys.implementation.name, which is "apython";
; platform.python_implementation() has no hook for one and answers "CPython".
; DIVERGENCES.md records that.
sm_version_val:  db "3.12.9 (apython ", VERSION_STR, ") [NASM x86-64]", 0
sm_version_info: db "version_info", 0
sm_float_info:   db "float_info", 0
sm_flags:        db "flags", 0
sm_int_info:     db "int_info", 0
sm_hash_info:    db "hash_info", 0
sm_thread_info:  db "thread_info", 0
sm_final:        db "final", 0
sm_executable:   db "executable", 0
sm_prefix:       db "prefix", 0
sm_exec_prefix:  db "exec_prefix", 0
sm_base_prefix:      db "base_prefix", 0
sm_base_exec_prefix: db "base_exec_prefix", 0
sm_platlibdir:   db "platlibdir", 0
sm_abiflags:     db "abiflags", 0
sm_lib:          db "lib", 0
sm_copyright:        db "copyright", 0
sm_copyright_text:
    db "Copyright (c) 2026 Jeff Garzik.", 10
    db "All Rights Reserved.", 10
    db 10
    db "Portions of the standard library are", 10
    db "Copyright (c) 2001-2026 Python Software Foundation.", 10
    db "All Rights Reserved.", 0
sm_stdout:       db "stdout", 0
sm_stderr:       db "stderr", 0
sm_stdin:        db "stdin", 0
sm_stdout_name:  db "<stdout>", 0
sm_stderr_name:  db "<stderr>", 0
sm_stdin_name:   db "<stdin>", 0
sm_mode_w:       db "w", 0
sm_mode_r:       db "r", 0
sm_exit:         db "exit", 0
sm_getrecursionlimit: db "getrecursionlimit", 0
sm_setrecursionlimit: db "setrecursionlimit", 0
sm_implementation: db "implementation", 0
sm_name:         db "name", 0
sm_apython_name: db "apython", 0
sm_cache_tag:    db "cache_tag", 0
sm_cache_tag_val: db "apython-312", 0
sm_warnoptions:  db "warnoptions", 0
sm_builtin_module_names: db "builtin_module_names", 0

; The CPython builtins this tree supplies from lib/ instead.  Each is found
; with no path entry, so saying it is built in is what a program observes.
sm_n_thread:      db "_thread", 0
sm_n_warnings:    db "_warnings", 0
sm_n_imp:         db "_imp", 0
sm_n_codecs:      db "_codecs", 0
sm_n_collections: db "_collections", 0
sm_n_operator:    db "_operator", 0
sm_n_string:      db "_string", 0
sm_n_random:      db "_random", 0
sm_n_contextvars: db "_contextvars", 0
sm_n_typing:      db "_typing", 0
sm_n_atexit:      db "atexit", 0
sm_n_binascii:    db "binascii", 0
sm_n_itertools:   db "itertools", 0
sm_n_tokenize:    db "_tokenize", 0
sm_n_ast:         db "_ast", 0
sm_n_struct:      db "_struct", 0
align 8
sm_supplied_names:
    dq sm_n_thread, sm_n_warnings, sm_n_imp, sm_n_codecs, sm_n_collections
    dq sm_n_operator, sm_n_string, sm_n_random, sm_n_contextvars, sm_n_typing
    dq sm_n_atexit, sm_n_binascii, sm_n_itertools, sm_n_tokenize, sm_n_ast
    dq sm_n_struct
SM_SUPPLIED_COUNT equ 16
sm_audit:         db "audit", 0
sm_addaudithook:  db "addaudithook", 0
sm_getfsencoding: db "getfilesystemencoding", 0
sm_getfsencodeerrors: db "getfilesystemencodeerrors", 0
sm_surrogateescape: db "surrogateescape", 0
sm_intern:       db "intern", 0
sm_excepthook:   db "excepthook", 0
sm_dunder_excepthook: db "__excepthook__", 0
sm_dunder_unraisablehook: db "__unraisablehook__", 0
sm_unraisablehook: db "unraisablehook", 0
sm_exc_info:     db "exc_info", 0
sm_exception:    db "exception", 0
sm_hexversion:   db "hexversion", 0
sm_maxunicode:   db "maxunicode", 0
sm_float_repr_style: db "float_repr_style", 0
sm_short:        db "short", 0
sm_dont_write_bytecode: db "dont_write_bytecode", 0
sm_path_importer_cache: db "path_importer_cache", 0
sm_meta_path:    db "meta_path", 0
sm_pycache_prefix: db "pycache_prefix", 0
sm_path_hooks:   db "path_hooks", 0
sm_get_asyncgen_hooks: db "get_asyncgen_hooks", 0
sm_set_asyncgen_hooks: db "set_asyncgen_hooks", 0
sm_firstiter:    db "firstiter", 0
sm_finalizer:    db "finalizer", 0
sm_displayhook:  db "displayhook", 0
sm_dunder_displayhook: db "__displayhook__", 0
sm_getrefcount:  db "getrefcount", 0
sm_is_finalizing: db "is_finalizing", 0
sm_underscore:   db "_", 0
sm_dunder_stdout: db "__stdout__", 0
sm_dunder_stderr: db "__stderr__", 0
sm_dunder_stdin:  db "__stdin__", 0
sm_getframe:     db "_getframe", 0
sm_getsizeof:    db "getsizeof", 0
sm_orig_argv:    db "orig_argv", 0
sm_clear_type_cache: db "_clear_type_cache", 0
sm_current_frames: db "_current_frames", 0
sm_breakpointhook: db "breakpointhook", 0
sm_dunder_breakpointhook: db "__breakpointhook__", 0
sm_api_version:  db "api_version", 0
sm_xoptions:     db "_xoptions", 0
sm_git:          db "_git", 0
sm_apython:      db "apython", 0
sm_dunder_spec:  db "__spec__", 0
sm_dunder_loader: db "__loader__", 0
sm_dunder_package: db "__package__", 0
sm_getframemodulename: db "_getframemodulename", 0
sm_settrace:     db "settrace", 0
sm_gettrace:     db "gettrace", 0
sm_setprofile:   db "setprofile", 0
sm_getprofile:   db "getprofile", 0
sm_call_tracing: db "call_tracing", 0
sm_byteorder:    db "byteorder", 0
sm_little:       db "little", 0
sm_getdefaultencoding: db "getdefaultencoding", 0
sm_get_int_max_str_digits: db "get_int_max_str_digits", 0
sm_set_int_max_str_digits: db "set_int_max_str_digits", 0
sm_get_coroutine_origin_tracking_depth: db "get_coroutine_origin_tracking_depth", 0
sm_set_coroutine_origin_tracking_depth: db "set_coroutine_origin_tracking_depth", 0
sm_utf8:         db "utf-8", 0
sm_empty:        db "", 0
sm_slash:        db "/", 0
sm_dot:          db ".", 0

section .bss
global sys_modules_dict
sys_modules_dict: resq 1

global sys_path_list
sys_path_list: resq 1

global sys_module_obj
sys_module_obj: resq 1

global sys_stdout_obj
sys_stdout_obj: resq 1

; PEP 525's two hooks, per interpreter.  An event loop installs them so that it
; learns about every async generator started under it and can close the ones
; still suspended when it shuts down; CPython's BaseEventLoop.run_forever reads
; them on its first line, which is why their absence stopped asyncio outright.
; NULL means "no hook", which is what a program sees as None.
; asyncgen_firstiter_hook / asyncgen_finalizer_hook lives in ThreadState (src/include/threadstate.inc).

; Set once, by main's teardown, before the first finalizer runs.  It is what
; sys.is_finalizing() answers, and the reason it is here rather than in main is
; that the reader is here: a __del__ asking "am I running at shutdown?" is
; asking whether the interpreter around it is still whole, and from Python
; there is only one way to ask.
global interp_finalizing
interp_finalizing: resq 1

; PEP 567's coroutine-origin tracking depth.  Nothing here reads it -- a
; coroutine carries no cr_origin -- but asyncio's event loop SETS it on every
; run_forever and GETS it back on the way out, so a missing pair is not a
; missing feature, it is a dead event loop.  An int that remembers what it was
; told is the whole contract a caller can observe; CPython's affects only the
; traceback a coroutine created under it carries.  coroutine_origin_depth
; lives in ThreadState (src/include/threadstate.inc).

section .data
align 8
; Not in .bss: the source compiler consults this to reject an over-long
; decimal literal, and ./apython foo.py compiles before sysmodule_init runs.
global sys_int_max_str_digits
sys_int_max_str_digits: dq 4300

sys_intern_table: dq 0

section .text

;; ============================================================================
;; sys.excepthook(type, value, traceback)
;;
;; The report the interpreter prints for an uncaught exception, on stderr.
;; threading saves and restores this around a thread's run(), and reads it at
;; import time -- which is where CPython's threading.py stopped.
;;
;; Only the VALUE is used: the exception object carries its own type and
;; traceback, and CPython's C hook falls back on the same when the three
;; arguments disagree.
;; ============================================================================

;; ============================================================================
;; sys_getrefcount_func(args, nargs) -> Value: the object's reference count
;;
;; The count INCLUDES the reference this call's own argument holds -- CPython
;; documents its answer as one higher than expected for exactly that reason,
;; and the args array here points into the value stack, whose slot holds one.
;; So the two agree on what a program can actually measure, which is the
;; DIFFERENCE a binding makes.
;;
;; A Value that is not a pointer -- an int immediate, a float -- is not an
;; object and has no count.  CPython's nearest thing is an immortal object,
;; and 3.12 reports 4294967295 for one; `sys.getrefcount(5)` answers that
;; there and answers it here.
;; ============================================================================
SGR_IMMORTAL equ 4294967295
DEF_FUNC sys_getrefcount_func
    cmp rsi, 1
    jne .sgr_args
    mov rdi, [rdi]
    V_TEST_PTR rdi, rax
    ja .sgr_immortal
    test rdi, rdi
    jz .sgr_immortal
    mov rax, [rdi + PyObject.ob_refcnt]
    V_PACK_I64 rax, rcx
    leave
    ret
.sgr_immortal:
    mov rax, SGR_IMMORTAL
    V_PACK_I64 rax, rcx
    leave
    ret
.sgr_args:
    RAISE exc_TypeError_type, "getrefcount() takes exactly one argument"
END_FUNC sys_getrefcount_func

;; ============================================================================
;; sys_is_finalizing_func(args, nargs) -> Value: True during teardown
;;
;; Whether the interpreter is shutting down.  A finalizer is the only Python
;; that runs after teardown begins, and this is the only way one can ask --
;; asyncio's BaseEventLoop.close() and unix_events.py open with it, and
;; threading, logging and concurrent.futures all branch on it before touching
;; anything they might no longer own.
;;
;; main's teardown sets the flag before the shutdown collection, which is
;; where those finalizers run, and nothing clears it: there is no way back.
;; ============================================================================
DEF_FUNC sys_is_finalizing_func
    test rsi, rsi
    jne .sif_args
    lea rax, [rel bool_false]
    cmp qword [rel interp_finalizing], 0
    je .sif_out
    lea rax, [rel bool_true]
.sif_out:
    mov rdi, rax
    push rax
    push rax                    ; pad: obj_incref must be called aligned
    call obj_incref
    pop rax
    pop rax
    leave
    ret
.sif_args:
    RAISE exc_TypeError_type, "is_finalizing() takes no arguments"
END_FUNC sys_is_finalizing_func

;; ============================================================================
;; sys_get_asyncgen_hooks_func(args, nargs) -> Value: an asyncgen_hooks pair
;;
;; PEP 525.  A struct sequence rather than a namespace, because CPython's event
;; loop restores the pair by splatting it back -- `set_asyncgen_hooks(*old)` --
;; while reading .firstiter and .finalizer by name elsewhere.  NULL storage
;; reads as None, which is what "no hook" looks like from Python.
;; ============================================================================
GAH_OBJ   equ 8
GAH_FRAME equ 24            ; + 1 push = 32, 16-aligned
DEF_FUNC sys_get_asyncgen_hooks_func, GAH_FRAME
    push rbx
    test rsi, rsi
    jnz .gah_args
    extern asyncgen_hooks_type
    lea rdi, [rel asyncgen_hooks_type]
    call structseq_new
    test rax, rax
    jz .gah_nomem
    mov [rbp - GAH_OBJ], rax

    ; obj_incref answers nothing -- rax still holds the object structseq_new
    ; gave back -- so the value is carried in rbx rather than read out of rax.
    ; Taken from rax, the pair stored ITSELF in both fields, and its repr
    ; recursed until the machine stack ran out.
    mov rbx, [gs:ThreadState.asyncgen_firstiter_hook]
    test rbx, rbx
    jnz .gah_have_first
    lea rbx, [rel none_singleton]
.gah_have_first:
    mov rdi, rbx
    call obj_incref             ; structseq_set takes over a reference
    mov rdi, [rbp - GAH_OBJ]
    xor esi, esi
    mov rdx, rbx
    call structseq_set

    mov rbx, [gs:ThreadState.asyncgen_finalizer_hook]
    test rbx, rbx
    jnz .gah_have_final
    lea rbx, [rel none_singleton]
.gah_have_final:
    mov rdi, rbx
    call obj_incref
    mov rdi, [rbp - GAH_OBJ]
    mov esi, 1
    mov rdx, rbx
    call structseq_set

    mov rax, [rbp - GAH_OBJ]
    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx
    ret
.gah_args:
    RAISE exc_TypeError_type, "get_asyncgen_hooks() takes no arguments"
.gah_nomem:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC sys_get_asyncgen_hooks_func

;; ============================================================================
;; sys_set_asyncgen_hooks_func(args, nargs) -> Value: None
;;
;; Takes firstiter and finalizer, positionally or by keyword -- CPython's event
;; loop uses the keyword form to install and the positional splat to restore.
;; An argument left out leaves that half alone, as CPython's does; None clears
;; it; anything else must be callable.
;; ============================================================================
SAH_ARGS  equ 8
SAH_NARGS equ 16
SAH_FRAME equ 40            ; + 1 push = 48, 16-aligned
DEF_FUNC sys_set_asyncgen_hooks_func, SAH_FRAME
    push rbx
    mov [rbp - SAH_ARGS], rdi
    mov [rbp - SAH_NARGS], rsi

    ; The keyword names, if any, are in kw_names_pending, and the values sit
    ; at the end of the positional array -- the shape every builtin here reads.
    mov rbx, [gs:ThreadState.kw_names_pending]
    mov qword [gs:ThreadState.kw_names_pending], 0

    ; Positional first: args[0] is firstiter, args[1] is finalizer.
    xor ecx, ecx                ; i = 0
    mov rdx, [rbp - SAH_NARGS]
    test rbx, rbx
    jz .sah_pos_count
    sub rdx, [rbx + PyTupleObject.ob_size]   ; the keywords are not positional
.sah_pos_count:
    cmp rdx, 2
    jg .sah_too_many
.sah_pos_loop:
    cmp rcx, rdx
    jge .sah_kw
    mov rax, [rbp - SAH_ARGS]
    mov rdi, [rax + rcx*8]
    mov esi, ecx                ; 0 = firstiter, 1 = finalizer
    push rcx
    push rdx
    call sah_store
    pop rdx
    pop rcx
    test eax, eax
    jz .sah_bad
    inc rcx
    jmp .sah_pos_loop

.sah_kw:
    test rbx, rbx
    jz .sah_done
    xor ecx, ecx
.sah_kw_loop:
    cmp rcx, [rbx + PyTupleObject.ob_size]
    jge .sah_done
    mov rax, [rbx + PyTupleObject.ob_item]
    mov rdi, [rax + rcx*8]      ; the keyword name str
    lea rsi, [rdi + PyStrObject.data]
    CSTRING rdi, "firstiter"
    push rcx
    push rsi
    call ap_strcmp
    pop rsi
    pop rcx
    test eax, eax
    jz .sah_kw_first
    CSTRING rdi, "finalizer"
    push rcx
    push rsi
    call ap_strcmp
    pop rsi
    pop rcx
    test eax, eax
    jnz .sah_bad_keyword
    mov esi, 1
    jmp .sah_kw_have
.sah_kw_first:
    xor esi, esi
.sah_kw_have:
    ; The value: the keyword block sits at the tail of the positional array.
    mov rax, [rbp - SAH_NARGS]
    sub rax, [rbx + PyTupleObject.ob_size]
    add rax, rcx
    mov rdx, [rbp - SAH_ARGS]
    mov rdi, [rdx + rax*8]
    push rcx
    push rsi
    call sah_store
    pop rsi
    pop rcx
    test eax, eax
    jz .sah_bad
    inc rcx
    jmp .sah_kw_loop

.sah_done:
    lea rax, [rel none_singleton]
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.sah_bad:
    ; Unreachable: sah_store raises rather than returning 0.  Kept so the
    ; caller reads as a checked call.
    pop rbx
    leave
    ret
.sah_too_many:
    RAISE exc_TypeError_type, "set_asyncgen_hooks() takes at most 2 arguments"
.sah_bad_keyword:
    RAISE exc_TypeError_type, \
        "set_asyncgen_hooks() got an unexpected keyword argument"
END_FUNC sys_set_asyncgen_hooks_func

;; ============================================================================
;; sah_store(rdi = Value, esi = 0 for firstiter / 1 for finalizer)
;;   -> eax = 1 stored, 0 with a TypeError recorded
;;
;; None clears the hook; anything else has to be callable, which is the one
;; thing CPython checks here.  The hook is held for the life of the setting,
;; so the old one is released.
;; ============================================================================
SAHS_VAL   equ 8
SAHS_WHICH equ 16
SAHS_FRAME equ 16           ; 0 pushes, 16-aligned
DEF_FUNC_LOCAL sah_store, SAHS_FRAME
    mov [rbp - SAHS_VAL], rdi
    mov [rbp - SAHS_WHICH], rsi

    lea rcx, [rel none_singleton]
    cmp rdi, rcx
    je .sahs_clear
    V_TEST_PTR rdi, rax
    ja .sahs_not_callable
    ; Callable is one line, as builtin_callable's comment says: a type whose
    ; tp_call is set has callable instances.
    mov rax, [rdi + PyObject.ob_type]
    cmp qword [rax + PyTypeObject.tp_call], 0
    je .sahs_not_callable
    mov rdi, [rbp - SAHS_VAL]
    call obj_incref
    mov rdx, [rbp - SAHS_VAL]
    jmp .sahs_put
.sahs_clear:
    xor edx, edx
.sahs_put:
    cmp qword [rbp - SAHS_WHICH], 0
    jne .sahs_final
    mov rdi, [gs:ThreadState.asyncgen_firstiter_hook]
    mov [gs:ThreadState.asyncgen_firstiter_hook], rdx
    jmp .sahs_release
.sahs_final:
    mov rdi, [gs:ThreadState.asyncgen_finalizer_hook]
    mov [gs:ThreadState.asyncgen_finalizer_hook], rdx
.sahs_release:
    test rdi, rdi
    jz .sahs_ok
    call obj_decref
.sahs_ok:
    mov eax, 1
    leave
    ret
.sahs_not_callable:
    ; CPython names the half it was given, so the message says which argument
    ; was wrong.
    mov rsi, [rbp - SAHS_VAL]
    cmp qword [rbp - SAHS_WHICH], 0
    jne .sahs_bad_final
    CSTRING rdi, `callable firstiter expected, got \x01`
    jmp .sahs_raise
.sahs_bad_final:
    CSTRING rdi, `callable finalizer expected, got \x01`
.sahs_raise:
    extern raise_type_error_with_name
    jmp raise_type_error_with_name  ; does not return
END_FUNC sah_store

;; ============================================================================
;; sys_displayhook_func(args, nargs) -> Value: None
;;
;; What an interactive prompt does with the value of an expression statement:
;; None is dropped silently, anything else is printed as its repr and bound to
;; builtins._ so the next line can refer to it.  Nothing in this tree calls it
;; -- there is no REPL -- but `sys.displayhook is sys.__displayhook__` is how
;; a program asks whether anything has replaced the hook, and code.py, pdb and
;; doctest all read it.
;;
;; builtins._ is set AFTER the print, as CPython sets it: a repr that raises
;; must not leave the name bound to a value the user never saw.
;; ============================================================================
SDH_VAL   equ 8
SDH_REPR  equ 16
SDH_KW    equ 24
SDH_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
DEF_FUNC sys_displayhook_func, SDH_FRAME
    cmp rsi, 1
    jne .sdh_args
    mov rdi, [rdi]
    mov [rbp - SDH_VAL], rdi
    lea rax, [rel none_singleton]
    cmp rdi, rax
    je .sdh_none

    extern obj_repr
    call obj_repr
    test rax, rax
    jz .sdh_failed
    mov [rbp - SDH_REPR], rax

    ; print() reads kw_names_pending, and whatever called US may have left one
    ; there.  Saved and restored rather than cleared, because a caller further
    ; up is entitled to find it as it was.
    mov rax, [gs:ThreadState.kw_names_pending]
    mov [rbp - SDH_KW], rax
    mov qword [gs:ThreadState.kw_names_pending], 0
    lea rdi, [rbp - SDH_REPR]
    mov esi, 1
    extern builtin_print
    call builtin_print
    mov rax, [rbp - SDH_KW]
    mov [gs:ThreadState.kw_names_pending], rax

    mov rdi, [rbp - SDH_REPR]
    call obj_decref

    ; builtins._ = value
    lea rdi, [rel sm_underscore]
    call str_from_cstr_heap
    push rax
    push rax                    ; pad
    extern builtins_dict_global
    mov rdi, [rel builtins_dict_global]
    mov rsi, rax
    mov rdx, [rbp - SDH_VAL]
    call dict_set
    pop rdi
    pop rdi
    call obj_decref

.sdh_none:
    RET_NONE
    leave
    V_PACK rax, rdx
    ret

.sdh_failed:
    leave
    xor eax, eax
    ret

.sdh_args:
    RAISE exc_TypeError_type, "displayhook() takes exactly one argument"
END_FUNC sys_displayhook_func

DEF_FUNC sys_excepthook_func
    cmp rsi, 3
    jl .seh_args
    mov rdi, [rdi + 8]          ; args[1], the exception
    ; "is a pointer" is not "is an exception": None is a pointer too, and
    ; `sys.excepthook(*sys.exc_info())` outside an except block passes three
    ; of them.  traceback_print read the exception's own fields off it.
    push rdi
    extern value_type
    call value_type             ; a Value, which may be an immediate
    pop rdi
    test rax, rax
    jz .seh_bad
    push rdi
    push rax
    mov rdi, rax
    extern exc_BaseException_type
    lea rsi, [rel exc_BaseException_type]
    extern type_is_subtype
    call type_is_subtype
    pop rsi                     ; the type
    pop rdi                     ; the value
    test eax, eax
    jz .seh_not_exc
    extern traceback_print
    call traceback_print
    LOAD_NONE rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
.seh_not_exc:
    ; CPython REPORTS this rather than raising it -- the hook is what runs
    ; when there is nothing left to catch anything, so it prints the TypeError
    ; on stderr and returns.  Same text, same place.  rsi = the type.
    push rsi
    extern tb_write_cstr
    lea rdi, [rel seh_not_exc_msg]
    call tb_write_cstr
    pop rdi
    mov rdi, [rdi + PyTypeObject.tp_name]
    call tb_write_cstr
    lea rdi, [rel seh_not_exc_end]
    call tb_write_cstr
    LOAD_NONE rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
.seh_bad:
    RAISE exc_TypeError_type, "excepthook(): Exception expected for value"
.seh_args:
    RAISE exc_TypeError_type, "excepthook() takes exactly 3 arguments"
END_FUNC sys_excepthook_func

;; ============================================================================
;; sys.unraisablehook(unraisable)
;;
;; What CPython calls for an exception that cannot be propagated -- in a
;; __del__, or in a generator being finalised.  The argument is a structseq;
;; the only field this can use is exc_value, and a missing one is not an
;; error, because the whole point of the hook is that nothing escapes it.
;; ============================================================================
UNH_EXC   equ 8
UNH_KEY   equ 16
UNH_ARG   equ 24
UNH_OBJ   equ 32
UNH_FRAME equ 48            ; + 0 pushes = 48
DEF_FUNC sys_unraisablehook_func, UNH_FRAME
    mov qword [rbp - UNH_OBJ], 0
    test rsi, rsi
    jz .suh_done
    mov rdi, [rdi]
    V_TEST_PTR rdi, rax
    ja .suh_done
    test rdi, rdi
    jz .suh_done
    mov [rbp - UNH_EXC], rdi
    mov [rbp - UNH_ARG], rdi

    ; The object the exception came out of, for the first line of the report.
    CSTRING rdi, "object"
    call str_from_cstr_heap
    mov [rbp - UNH_KEY], rax
    mov rdi, [rbp - UNH_ARG]
    mov rsi, rax
    call obj_getattr_opt
    push rax
    mov rdi, [rbp - UNH_KEY]
    call obj_decref
    pop rax
    test rax, rax
    jz .suh_no_object
    V_TEST_PTR rax, rcx
    ja .suh_drop_object
    mov [rbp - UNH_OBJ], rax
    jmp .suh_no_object
.suh_drop_object:
    mov rdi, rax
    XDECREF_V rdi, rcx
.suh_no_object:

    CSTRING rdi, "exc_value"
    extern str_from_cstr_heap
    call str_from_cstr_heap
    mov [rbp - UNH_KEY], rax
    mov rdi, [rbp - UNH_EXC]
    mov rsi, rax
    extern obj_getattr_opt
    call obj_getattr_opt
    mov [rbp - UNH_EXC], rax
    mov rdi, [rbp - UNH_KEY]
    call obj_decref
    mov rax, [rbp - UNH_EXC]
    test rax, rax
    jz .suh_done
    V_TEST_PTR rax, rcx
    ja .suh_drop
    ; The whole report, object line included -- the same one the interpreter
    ; prints when nothing has replaced this hook.
    mov rdi, rax
    mov rsi, [rbp - UNH_OBJ]
    extern traceback_unraisable_default
    call traceback_unraisable_default
.suh_drop:
    mov rdi, [rbp - UNH_EXC]
    XDECREF_V rdi, rcx
    mov rdi, [rbp - UNH_OBJ]
    test rdi, rdi
    jz .suh_done
    call obj_decref
.suh_done:
    LOAD_NONE rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
END_FUNC sys_unraisablehook_func


;; ============================================================================
;; sys.exc_info() -> (type, value, traceback), or (None, None, None)
;;
;; The exception being handled -- handled_exception, which an except block
;; installs and POP_EXCEPT takes down, and which a generator carries across a
;; suspension in PyFrame.exc_state.  Reading current_exception here answered
;; None from an `await` inside a handler onwards, and answered an exception
;; that was merely in flight in places where nothing was being handled at all.
;; threading reads it to report a thread that died, and CPython's contextlib
;; and unittest both use it.
;; ============================================================================
DEF_FUNC sys_exc_info_func
    mov rax, [gs:ThreadState.handled_exception]
    test rax, rax
    jz .sei_none
    push rax
    sub rsp, 8
    mov edi, 3
    extern tuple_new
    call tuple_new
    add rsp, 8
    pop rcx
    test rax, rax
    jz .sei_failed
    mov rdx, [rax + PyTupleObject.ob_item]
    mov rsi, [rcx + PyObject.ob_type]
    INCREF rsi
    mov [rdx], rsi
    INCREF rcx
    mov [rdx + 8], rcx
    mov rsi, [rcx + PyExceptionObject.exc_tb]
    test rsi, rsi
    jnz .sei_have_tb
    LOAD_NONE rsi
.sei_have_tb:
    INCREF rsi
    mov [rdx + 16], rsi
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
.sei_failed:
    xor eax, eax
    leave
    ret

.sei_none:
    mov edi, 3
    call tuple_new
    test rax, rax
    jz .sei_failed
    mov rdx, [rax + PyTupleObject.ob_item]
    LOAD_NONE rcx
    INCREF rcx
    mov [rdx], rcx
    INCREF rcx
    mov [rdx + 8], rcx
    INCREF rcx
    mov [rdx + 16], rcx
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
END_FUNC sys_exc_info_func

;; ============================================================================
;; sys.exception() -> the exception being handled, or None
;;   -> rax = Value: handled_exception with a new reference, else None
;;
;; 3.11 added this as the one-value form of exc_info(), and CPython's own
;; traceback.py is written against it -- format_exc() is literally
;; "".join(format_exception(sys.exception(), ...)), so without this every
;; traceback.format_exc() and print_exc() raised AttributeError.  pdb reads it
;; too.
;;
;; Same source as exc_info's first element and for the same reason: the
;; exception being HANDLED, not the one merely in flight.
;; ============================================================================
DEF_FUNC sys_exception_func
    mov rax, [gs:ThreadState.handled_exception]
    test rax, rax
    jnz .sx_have
    LOAD_NONE rax
.sx_have:
    INCREF rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
END_FUNC sys_exception_func
