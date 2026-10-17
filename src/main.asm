; main.asm - Entry point for apython
; Parses argv, loads .pyc, creates frame, runs bytecode

%include "macros.inc"
%include "object.inc"
%include "compiler.inc"

extern bool_init
extern ap_strcmp
extern value_selftest_main
extern compile_selftest_main
extern alloc_selftest_main
extern dis_main
extern dis_mode
extern builtins_init
extern methods_init
extern import_init
extern sys_path_add_script_dir
extern dict_new
extern dict_set
extern frame_new
extern frame_free
extern frame_pool_drain
extern eval_frame
extern code_from_path
extern fatal_error
extern obj_decref
extern str_from_cstr_heap
extern none_singleton
extern module_new
extern sys_modules_dict
extern sys_module_obj
extern sys_write

;; ============================================================================
;; main(int argc, char **argv) -> int
;; The 8 pads the five pushes to a 16-aligned rsp.  main holds argc and argv in
;; r14/r15 across the whole compile, so a source file with a float literal
;; reaches glibc's strtod from here -- and that is one of the few call paths out
;; of this codebase that actually uses aligned SSE.
;; ============================================================================
DEF_FUNC main, 8
    push rbx
    push r12
    push r13
    push r14
    push r15

    ; Check argc >= 2
    cmp edi, 2
    jl .usage

    ; Save argc/argv early
    mov r14d, edi               ; r14 = argc
    mov r15, rsi                ; r15 = argv

    ; And keep a COPY of the original pointer array, for sys.orig_argv.  Not
    ; the array itself: the flag loop shifts r15 past what it consumes and
    ; -c writes its own token OVER the command in place, so by the time sys
    ; is built the caller's array no longer holds what the process was
    ; started with.  sys.orig_argv is every one of those tokens, which is how
    ; a program re-execs itself with the same options.
    mov [rel main_orig_argc], rdi
    push rdi
    push rsi
    shl rdi, 3
    extern ap_malloc
    call ap_malloc
    pop rsi
    pop rdi
    test rax, rax
    jz .orig_argv_skipped
    mov [rel main_orig_argv], rax
    xor ecx, ecx
.orig_argv_copy:
    cmp rcx, rdi
    jge .orig_argv_skipped
    mov rdx, [rsi + rcx*8]
    mov [rax + rcx*8], rdx
    inc rcx
    jmp .orig_argv_copy
.orig_argv_skipped:
    mov r14d, edi               ; the copy loop clobbered neither, but be
    mov r15, rsi                ; explicit: these are the working pair

    ; Check for --version flag
    mov rax, [r15 + 8]          ; rax = argv[1]
    cmp word [rax], 0x2d2d      ; "--" little-endian
    jne .not_version
    mov rcx, [rax + 2]          ; load 8 bytes: "version\0"
    mov rdx, 0x006e6f6973726576 ; "version\0" little-endian
    cmp rcx, rdx
    jne .not_version

    ; Print version and exit 0
    mov edi, 1                  ; stdout
    lea rsi, [rel version_msg]
    mov edx, version_msg_len
    call sys_write
    xor eax, eax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
.not_version:

    ; Check for -h / --help / -?  CPython accepts all three, writes the help to
    ; stdout and exits 0, so we do the same.  The options listed are ours: a
    ; help screen naming flags this interpreter does not implement would be
    ; worse than no help screen at all.
    mov rdi, [r15 + 8]          ; rdi = argv[1]
    lea rsi, [rel help_flag]
    call ap_strcmp
    test eax, eax
    je .do_help
    mov rdi, [r15 + 8]
    lea rsi, [rel help_short_flag]
    call ap_strcmp
    test eax, eax
    je .do_help
    mov rdi, [r15 + 8]
    lea rsi, [rel help_q_flag]
    call ap_strcmp
    test eax, eax
    jne .not_help
.do_help:
    mov edi, 1                  ; stdout
    lea rsi, [rel help_msg]
    mov edx, help_msg_len
    call sys_write
    xor eax, eax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
.not_help:

    ; Check for --selftest-value flag (NaN-box encoding self-test)
    mov rdi, [r15 + 8]          ; rdi = argv[1]
    lea rsi, [rel selftest_flag]
    call ap_strcmp
    test eax, eax
    jne .not_selftest
    call bool_init
    call value_selftest_main
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
.not_selftest:

    ; Check for --selftest-compile flag (source compiler self-test)
    mov rdi, [r15 + 8]          ; rdi = argv[1]
    lea rsi, [rel selftest_compile_flag]
    call ap_strcmp
    test eax, eax
    jne .not_selftest_compile
    call bool_init
    call compile_selftest_main
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
.not_selftest_compile:

    ; Check for --selftest-alloc flag (the pool allocator, without the
    ; interpreter: an allocator bug reaches Python as data corruption
    ; somewhere else entirely, so it is worth catching here)
    mov rdi, [r15 + 8]          ; rdi = argv[1]
    lea rsi, [rel selftest_alloc_flag]
    call ap_strcmp
    test eax, eax
    jne .not_selftest_alloc
    call alloc_selftest_main
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
.not_selftest_alloc:

    ; Check for --dis: compile argv[2] as an expression and print its bytecode.
    ; Fidelity is semantic rather than byte-for-byte, so putting this beside
    ; `python3 -m dis` is the quickest way to localise a codegen bug.
    mov rdi, [r15 + 8]
    lea rsi, [rel dis_flag]
    call ap_strcmp
    test eax, eax
    jne .not_dis
    cmp r14, 3                  ; argc
    jl .usage
    call bool_init
    ; `--dis -x <source>` disassembles in exec mode rather than eval mode.
    mov rdi, [r15 + 16]         ; argv[2]
    cmp byte [rdi], '-'
    jne .dis_go
    cmp byte [rdi + 1], 'x'
    jne .dis_go
    cmp r14, 4
    jl .usage
    mov qword [rel dis_mode], CMODE_EXEC
    mov rdi, [r15 + 24]
.dis_go:
    call dis_main
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
.not_dis:

    ; Check for -t flag (opcode tracing)
    mov rax, [r15 + 8]         ; rax = argv[1]
    cmp byte [rax], '-'
    jne .no_trace_flag
    cmp byte [rax + 1], 't'
    jne .no_trace_flag
    cmp byte [rax + 2], 0
    jne .no_trace_flag
    ; Point dispatch at the hook table.  Setting a flag was not enough: every
    ; handler dispatches inline and only eval_dispatch tested it.  Through
    ; eval_hooks_set, because sys.settrace wants the same table and the two
    ; must not overwrite each other.
    xor edi, edi                ; bit 0 = the -t printer
    mov esi, 1
    extern eval_hooks_set
    call eval_hooks_set
    add r15, 8                  ; skip -t in argv
    dec r14d                    ; adjust argc
    cmp r14d, 2
    jl .usage
.no_trace_flag:

    ; --- interpreter flags, and -c ---
    ;
    ; What test.support's script_helper sends is
    ;   [sys.executable, '-X', 'faulthandler'] + ('-I' or '-E') + the caller's
    ;   arguments, which are usually '-c' and a command.  Forty of CPython's
    ;   test modules cannot reach their first test without it.
    ;
    ; The single-letter flags are recorded in main_sysflags, which becomes
    ; sys.flags; -E, -s, -S, -I and -P are acted on further down.  Unknown
    ; flags are refused -- a lenient scan would swallow a filename beginning
    ; with '-'.
    mov qword [rel cmd_source], 0
.flag_loop:
    cmp r14d, 2
    jl .usage
    mov rax, [r15 + 8]
    cmp byte [rax], '-'
    jne .flags_done
    cmp byte [rax + 1], 0
    je .flag_stdin              ; a bare "-" is the program on stdin

    ; -c <command>.  CPython leaves sys.argv[0] as "-c" and drops the command
    ; itself, so move the "-c" token down over it and shift by one; what is
    ; left is ["-c", *the rest].
    cmp byte [rax + 1], 'c'
    jne .flag_not_c
    cmp byte [rax + 2], 0
    jne .flag_not_c
    cmp r14d, 3
    jl .usage
    mov rcx, [r15 + 8]          ; the "-c" token
    mov rdx, [r15 + 16]         ; the command
    mov [rel cmd_source], rdx
    mov [r15 + 16], rcx
    add r15, 8
    dec r14d
    jmp .flags_done

.flag_not_c:
    ; -m <module>.  Resolving a module name means walking sys.path and asking
    ; the import machinery, and neither exists this early -- code_from_path
    ; above runs before builtins_init and import_init.  So the flag becomes a
    ; fixed bootstrap command and the module NAME takes argv[1]'s place: that
    ; is where lib/_runmodule.py reads it from, and where CPython leaves the
    ; module's own file once it is resolved.
    ;
    ; sys.argv therefore comes out as [<module>, *the rest], which is
    ; CPython's shape, and sys_path_add_script_dir sees a name with no slash
    ; in it and answers "." -- the working directory, which is what CPython
    ; puts at sys.path[0] for -m.
    cmp byte [rax + 1], 'm'
    jne .flag_not_m
    cmp byte [rax + 2], 0
    jne .flag_not_m
    cmp r14d, 3
    jl .usage
    lea rax, [rel main_runmodule_cmd]
    mov [rel cmd_source], rax
    add r15, 8
    dec r14d
    jmp .flags_done

.flag_not_m:
    ; -X <opt> and -W <spec> take a second token; both are ignored whole.
    cmp byte [rax + 2], 0
    jne .flag_word
    movzx ecx, byte [rax + 1]
    cmp cl, 'X'
    je .flag_two
    cmp cl, 'W'
    je .flag_two

.flag_word:
    ; Every character after the '-' has to be one this accepts, so that -OO
    ; and -bb work and -z does not.
    lea rcx, [rax + 1]
.flag_char:
    movzx edx, byte [rcx]
    test dl, dl
    jz .flag_one
    lea rsi, [rel main_noop_flags]
.flag_char_scan:
    movzx edi, byte [rsi]
    test dil, dil
    jz .usage                   ; not one of ours
    cmp dil, dl
    je .flag_char_next
    inc rsi
    jmp .flag_char_scan
.flag_char_next:
    ; Each flag is a count in main_sysflags, at its sys.flags index; -I is
    ; -E -s -P as well as itself, and -B also seeds sys.dont_write_bytecode,
    ; which pyc_write_cache reads.  -u and -R are accepted and change nothing.
    lea rsi, [rel main_flag_chars]
    xor edi, edi
.flag_index:
    movzx eax, byte [rsi + rdi]
    test al, al
    jz .flag_specials
    cmp al, dl
    je .flag_count
    inc edi
    jmp .flag_index
.flag_count:
    lea rsi, [rel main_flag_index]
    movzx eax, byte [rsi + rdi]
    lea rsi, [rel main_sysflags]
    inc byte [rsi + rax]
.flag_specials:
    cmp dl, 'I'
    jne .flag_not_isolated
    mov byte [rel main_sysflags + SF_ISOLATED], 1
    mov byte [rel main_sysflags + SF_IGNORE_ENV], 1
    mov byte [rel main_sysflags + SF_NO_USER_SITE], 1
    mov byte [rel main_sysflags + SF_SAFE_PATH], 1
.flag_not_isolated:
    cmp dl, 'B'
    jne .flag_char_step
    mov byte [rel main_no_bytecode], 1
.flag_char_step:
    inc rcx
    jmp .flag_char

.flag_one:
    add r15, 8
    dec r14d
    jmp .flag_loop
.flag_two:
    cmp r14d, 3
    jl .usage
    ; Keep the option for sys.warnoptions / sys._xoptions, which
    ; main_sys_options builds once sys exists.  `-X dev` is also
    ; sys.flags.dev_mode, and sys.flags is built before then.
    mov rdx, [r15 + 16]             ; the option's argument
    movzx ecx, byte [rax + 1]
    cmp cl, 'W'
    jne .flag_two_x
    mov rcx, [rel main_wopt_count]
    cmp rcx, MAIN_OPT_MAX
    jae .flag_two_done
    lea rsi, [rel main_wopts]
    mov [rsi + rcx * 8], rdx
    inc qword [rel main_wopt_count]
    jmp .flag_two_done
.flag_two_x:
    mov rcx, [rel main_xopt_count]
    cmp rcx, MAIN_OPT_MAX
    jae .flag_two_done
    lea rsi, [rel main_xopts]
    mov [rsi + rcx * 8], rdx
    inc qword [rel main_xopt_count]
    cmp dword [rdx], 'dev'          ; "dev" and its NUL
    jne .flag_two_done
    mov byte [rel main_sysflags + SF_DEV_MODE], 1
.flag_two_done:
    add r15, 16
    sub r14d, 2
    jmp .flag_loop

.flag_stdin:
    ; `apython -` reads the program from standard input, as CPython does.  It
    ; used to be treated as a filename and reached pyc_read_file, which said
    ; "pyc: cannot open file" -- and a pipeline is how a generated program is
    ; usually handed to an interpreter.  The text is slurped whole and
    ; compiled like -c, under the filename CPython gives it.
    call main_read_stdin
    test rax, rax
    jz .stdin_failed
    mov [rel cmd_source], rax
    mov qword [rel cmd_is_stdin], 1
    jmp .flags_done

.flags_done:
    call main_env_flags

    ; Save argv[1] (the .pyc filename, or "-c", after any shift)
    mov rbx, [r15 + 8]         ; rbx = argv[1]

    ; A script is named by its absolute path from here on, as CPython has
    ; done since 3.9: it is __file__, every traceback's co_filename, and what
    ; sys.path[0] is the directory of.  sys.argv[0] keeps the path as given.
    cmp qword [rel cmd_source], 0
    jne .script_named
    mov rdi, rbx
    extern pathconfig_script
    call pathconfig_script
    mov rbx, rax
.script_named:

    ; Initialize subsystems
    call bool_init

    ; Load the file -> code object.  A .py is compiled here; anything else is
    ; read as marshalled bytecode.  With -c there is no file: the command is
    ; compiled in exec mode, exactly as `exec()` compiles a string.
    mov rdi, [rel cmd_source]
    test rdi, rdi
    jz .load_from_path
    ; r12 and r13 are the code object and the builtins dict further down, and
    ; are free until then; being callee-saved they survive the calls here.
    extern ap_strlen
    call ap_strlen
    mov r13, rax                ; the command's length
    extern str_from_cstr_heap
    CSTRING rdi, "<string>"
    cmp qword [rel cmd_is_stdin], 0
    je .cmd_have_name
    CSTRING rdi, "<stdin>"
.cmd_have_name:
    call str_from_cstr_heap
    mov r12, rax                ; the filename compile_source records
    mov rdi, [rel cmd_source]
    mov rsi, r13
    mov rdx, r12
    mov ecx, CMODE_EXEC
    extern compile_source
    call compile_source
    mov r13, rax
    mov rdi, r12
    call obj_decref
    mov rax, r13
    jmp .have_code
.load_from_path:
    mov rdi, rbx
    call code_from_path
.have_code:
    test rax, rax
    jz .load_failed
    mov r12, rax                ; r12 = code object

    ; Create builtins dict
    call builtins_init
    mov r13, rax                ; r13 = builtins dict

    ; Initialize type methods (str, list, dict tp_dict)
    call methods_init

    ; Initialize import system (sys module, sys.modules, etc.)
    mov edi, r14d               ; argc
    mov rsi, r15                ; argv
    call import_init
    call main_sys_options

    ; SIGINT raises KeyboardInterrupt rather than killing the process where it
    ; stands, which is what every `except KeyboardInterrupt` in the stdlib is
    ; written against.  After import_init, because it builds a builtin
    ; function object and the type machinery has to be up.
    extern signal_default_init
    call signal_default_init

    ; The SyntaxWarnings the compile recorded, now that there is an
    ; interpreter to emit them from: code_from_path above runs before
    ; builtins_init and import_init, so nothing could be imported then.
    extern comp_flush_warnings
    call comp_flush_warnings

    ; Create globals dict
    call dict_new
    push rax                    ; save globals dict on stack

    ; Set __name__ = "__main__" in globals
    lea rdi, [rel __name__cstr]
    call str_from_cstr_heap
    push rax                    ; save key str
    lea rdi, [rel __main__cstr]
    call str_from_cstr_heap
    push rax                    ; save value str
    mov rdx, rax                ; value = "__main__" str
    mov rsi, [rsp + 8]          ; key = "__name__" str
    mov rdi, [rsp + 16]         ; dict = globals (from stack)
    call dict_set
    pop rdi                     ; value str
    call obj_decref
    pop rdi                     ; key str
    call obj_decref

    ; Set __doc__ = None: a module without a docstring still HAS the name,
    ; and reading it was a NameError.  The body's own STORE_NAME overwrites
    ; this when there is a docstring.
    lea rdi, [rel __doc__cstr]
    call str_from_cstr_heap
    push rax
    mov rdi, [rsp + 8]         ; globals dict
    mov rsi, rax
    lea rdx, [rel none_singleton]
    call dict_set
    pop rdi
    call obj_decref

    ; Set __file__ to the path the script was named by.  CPython sets it for
    ; a script as readily as for an import, and code reads it constantly --
    ; os.path.dirname(__file__) is the ordinary way to find a data file.  Its
    ; absence is why trace.py counted nothing: globaltrace_lt reads
    ; frame.f_globals['__file__'] to decide whether to trace a module at all.
    lea rdi, [rel __file__cstr]
    call str_from_cstr_heap
    push rax
    mov rdi, rbx                ; the script path, as given on the command line
    call str_from_cstr_heap
    push rax
    mov rdx, rax
    mov rsi, [rsp + 8]
    mov rdi, [rsp + 16]         ; globals dict
    call dict_set
    pop rdi
    call obj_decref
    pop rdi
    call obj_decref

    ; Set __package__ = None in globals (top-level module has no package)
    lea rdi, [rel __package__cstr]
    call str_from_cstr_heap
    push rax
    mov rdi, [rsp + 8]         ; globals dict
    mov rsi, rax
    lea rdx, [rel none_singleton]
    call dict_set
    pop rdi
    call obj_decref

    ; Set __builtins__ in globals
    extern builtins_dict_global
    lea rdi, [rel __builtins__cstr]
    call str_from_cstr_heap
    push rax
    mov rdi, [rsp + 8]         ; globals dict
    mov rsi, rax
    mov rdx, [rel builtins_dict_global]
    call dict_set
    pop rdi
    call obj_decref

    pop rax                     ; rax = globals dict
    mov r14, rax                ; r14 = globals dict

    ; Create __main__ module and register in sys.modules
    lea rdi, [rel __main__cstr]
    call str_from_cstr_heap
    push rax                    ; save "__main__" name str
    mov rdi, rax
    mov rsi, r14                ; dict = globals
    call module_new
    push rax                    ; save module object
    ; Register in sys.modules
    mov rdi, [rel sys_modules_dict]
    mov rsi, [rsp + 8]         ; key = "__main__" str
    mov rdx, rax               ; value = module object
    call dict_set
    pop rdi                     ; module object (owned by sys.modules now)
    call obj_decref
    pop rdi                     ; "__main__" str
    call obj_decref

    ; site, unless -S: it is what adds site-packages, the user site and the
    ; .pth files, and sets up a venv.  CPython imports it after __main__
    ; exists and before sys.path[0] is the script's directory, and a failure
    ; is fatal there as it is here.
    ;
    ; Before it, under -S as well: CPython's importlib, which every import
    ; from here on goes through (lib/_importlib_bootstrap.py says how).
    CSTRING rdi, "import _importlib_bootstrap"
    mov esi, 27
    call main_run_startup
    test eax, eax
    jnz .check_uncaught
    cmp byte [rel main_sysflags + SF_NO_SITE], 0
    jne .site_done
    CSTRING rdi, "import site"
    mov esi, 11
    call main_run_startup
    test eax, eax
    jnz .check_uncaught
.site_done:

    ; sys.path[0]: the script's directory, '' for -c and stdin, and the
    ; working directory for -m -- which a trailing slash on it gives.
    mov rdi, rbx
    mov rax, [rel cmd_source]
    test rax, rax
    jnz .path0_not_script
    extern pathconfig_path0
    call pathconfig_path0
    mov rdi, rax
    jmp .path0_have
.path0_not_script:
    CSTRING rdi, ""
    lea rcx, [rel main_runmodule_cmd]
    cmp rax, rcx
    jne .path0_have
    extern pathconfig_cwd_dir
    call pathconfig_cwd_dir
    mov rdi, rax
.path0_have:
    call sys_path_add_script_dir

    ; Create execution frame
    ; frame_new(code, globals, builtins, locals)
    ; For module-level code, locals == globals
    mov rdi, r12                ; code
    mov rsi, r14                ; globals
    mov rdx, r13                ; builtins
    mov rcx, r14                ; locals = globals
    call frame_new
    mov rbx, rax                ; rbx = frame

    ; Execute the bytecode
    mov rdi, rbx
    call eval_frame
    V_UNPACK rax, rdx           ; eval_frame returns a Value
    ; rax = return value (ignore for module-level code)

    ; Clean up
    mov rdi, rbx
    call frame_free

    ; Check for unhandled exception
.check_uncaught:
    extern current_exception
    mov rdi, [rel current_exception]
    test rdi, rdi
    jz .exit_ok

    ; An uncaught SystemExit is the process status, not an error report.
    push rdi
    lea rsi, [rel exc_SystemExit_type]
    extern exc_SystemExit_type
    extern exc_isinstance
    call exc_isinstance
    pop rdi
    test eax, eax
    jnz .system_exit

    ; Print the traceback and the exception, CPython's shape.
    extern traceback_print
    ; Whatever is waiting on stdout goes out before the report does.  CPython
    ; flushes both streams in flush_io() on its way into the display routine,
    ; and it is what puts a program's output ahead of the traceback that ended
    ; it rather than after: the two streams are buffered differently, so
    ; without this the order through a pipe came out inverted.  The unraisable
    ; hook does NOT do it -- CPython's does not either.
    push rdi
    extern fileobj_flush_std
    call fileobj_flush_std
    pop rdi
    call traceback_print

    ; DECREF the exception object before exiting
    mov rdi, [rel current_exception]
    call obj_decref
    mov qword [rel current_exception], 0

    ; Exit 1
    mov ebx, 1
    jmp .exit_cleanup

.system_exit:
    ; SystemExit.code: absent or None -> 0, an int -> that status, anything
    ; else -> print it on stderr and exit 1.
    mov rax, [rdi + PyExceptionObject.exc_args]
    test rax, rax
    jz .se_zero
    mov rcx, [rax + PyTupleObject.ob_size]
    test rcx, rcx
    jz .se_zero
    mov rcx, [rax + PyTupleObject.ob_item]
    mov rax, [rcx]                 ; args[0] as a Value
    lea rcx, [rel none_singleton]
    cmp rax, rcx
    je .se_zero
    V_IS_INT rax, rcx
    jae .se_int
    V_TEST_PTR rax, rcx
    ja .se_one                     ; a float status is not a status
    mov rcx, [rax + PyObject.ob_type]
    extern int_type
    lea rdx, [rel int_type]
    cmp rcx, rdx
    je .se_bigint
    ; True and False are ints: sys.exit(False) exits 0, not 1.
    extern bool_type
    lea rdx, [rel bool_type]
    cmp rcx, rdx
    je .se_bigint
    extern str_type
    lea rdx, [rel str_type]
    cmp rcx, rdx
    jne .se_one
    ; A message: print it and exit 1.
    mov rdx, [rax + PyStrObject.ob_size]
    lea rsi, [rax + PyStrObject.data]
    mov edi, 2
    call sys_write
    mov edi, 2
    lea rsi, [rel newline_char]
    mov edx, 1
    call sys_write
    jmp .se_one

.se_bigint:
    ; A heap int still has to fit a process status; take it modulo 256 the
    ; way the kernel does with the low byte of the syscall argument.
    mov rdi, rax
    mov edx, TAG_PTR
    extern int_to_i64
    call int_to_i64
    mov ebx, eax
    and ebx, 0xff
    jmp .se_finish

.se_int:
    V_TO_I64 rax
    mov ebx, eax
    and ebx, 0xff
    jmp .se_finish

.se_one:
    mov ebx, 1
    jmp .se_finish

.se_zero:
    xor ebx, ebx
.se_finish:
    mov rdi, [rel current_exception]
    call obj_decref
    mov qword [rel current_exception], 0
    jmp .exit_cleanup

.exit_ok:
    xor ebx, ebx

.exit_cleanup:
    ; From here on the interpreter is coming apart, and the Python that still
    ; runs -- every __del__ the collection below fires -- is entitled to know
    ; it.  asyncio's loop.close() asks before touching its selector, and
    ; threading, logging and concurrent.futures all branch on the answer.
    extern interp_finalizing
    mov qword [rel interp_finalizing], 1

    ; Whatever is still waiting in stdout's buffer goes out first, and before
    ; the collection below: a __del__ that prints has to reach the same
    ; stream, in order, and a buffer abandoned at exit is output that was
    ; produced and never seen.
    extern fileobj_flush_std
    call fileobj_flush_std

    ; Finalize cyclic garbage while the interpreter is still whole.  CPython
    ; runs a full collection at shutdown, which is what makes a __del__ on an
    ; object in a cycle run at all; without one, every such cycle was simply
    ; abandoned.  It goes before the sys.modules cascade rather than after:
    ; module dicts are what most cycles hang off, and a collection run after
    ; they are torn down finds nothing to do.
    ;
    ; And BEFORE the sys cycle is broken, which is the whole interpreter this
    ; runs in: those finalizers are ordinary Python, and the first thing one
    ; does is `sys.stderr` or `sys.is_finalizing`.  With sys's dict already
    ; NULLed, module_getattr read a dict pointer of zero -- so any __del__ in
    ; a cycle that touched sys segfaulted the process at exit, after every
    ; line of output had been produced.
    extern gc_collect_gen
    mov edi, 2
    call gc_collect_gen

    ; ...and flush again.  Those finalizers are the last Python that runs,
    ; and `print` from one of them lands in the buffer the flush above just
    ; emptied.  CPython flushes after finalization for the same reason.
    call fileobj_flush_std

    ; stdout could not be emptied.  No Python saw this failure -- the bytes
    ; never left the buffer -- so CPython reports it through the unraisable
    ; hook and then exits 120, OVERRIDING whatever status the program asked
    ; for: `print("x"); sys.exit(3)` down a closed pipe exits 120, not 3.
    ; Reported here, after the traceback of an uncaught exception, because that
    ; is the order CPython prints the two in, and while allocation is still
    ; safe -- the collection just above has already run arbitrary __del__s.
    extern stdout_flush_errno
    mov rax, [rel stdout_flush_errno]
    test rax, rax
    jz .no_flush_failure
    mov qword [rel stdout_flush_errno], 0   ; report it once
    mov rdi, rax
    xor esi, esi
    xor edx, edx
    extern raise_oserror_build
    call raise_oserror_build        ; rax = a BrokenPipeError, owned
    test rax, rax
    jz .no_flush_failure
    push rax
    push rax                        ; twice: the call below stays aligned
    mov rdi, rax
    extern sys_stdout_obj
    mov rsi, [rel sys_stdout_obj]
    extern traceback_unraisable_default
    call traceback_unraisable_default
    pop rdi
    pop rdi
    call obj_decref
    mov ebx, 120
.no_flush_failure:

    ; Break sys.modules cycle, now that no more Python can run: sys_modules_dict -> sys module -> sys_dict
    ;   -> "modules" entry -> sys_modules_dict
    ; NULL out sys_module.mod_dict and DECREF the old dict twice:
    ;   once for creation ref, once for module_new INCREF
    ;   (module_dealloc won't DECREF since we NULLed mod_dict)
    mov rax, [rel sys_module_obj]
    test rax, rax
    jz .no_sys_module
    mov rdi, [rax + PyModuleObject.mod_dict]
    mov qword [rax + PyModuleObject.mod_dict], 0
    test rdi, rdi
    jz .no_sys_module
    push rdi
    call obj_decref
    pop rdi
    call obj_decref
.no_sys_module:

    ; DECREF owned objects.
    ;
    ; sys.modules goes first, and before the code object.  Freeing it cascades
    ; into every module dict -- __main__'s among them, which is the globals
    ; dict -- and those dicts hold strings that came out of the running code
    ; object's co_consts and co_names.  Releasing the code object first drove
    ; some of those to zero, and the module teardown then read freed memory:
    ; valgrind saw the invalid read in dict_dealloc, and libc's allocator
    ; noticed it as "unaligned fastbin chunk" once an unrelated change moved
    ; the heap around.  The missing INCREF behind it was in
    ; sre_match_groupdict_method and is fixed; this order is kept because
    ; dropping the users before the object they borrow from is right anyway,
    ; and it stops the next such bug from being a crash at teardown.
    mov rdi, [rel sys_modules_dict]
    call obj_decref

    mov rdi, r14            ; globals dict
    call obj_decref
    mov rdi, r12            ; code object
    call obj_decref

    ; DECREF builtins dict (after sys.modules cascade reduced its refcount)
    mov rdi, [rel builtins_dict_global]
    call obj_decref

    ; Drain frame pools
    call frame_pool_drain

    mov eax, ebx
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret

.stdin_failed:
    CSTRING rdi, "Error: cannot read the program from standard input"
    call fatal_error

.usage:
    ; A usage error exits 2, as CPython's does -- 1 is a program that ran and
    ; failed, and a caller that tells the two apart (script_helper does) reads
    ; a bad invocation as a failed run otherwise.
    CSTRING rdi, "usage: apython [option] ... [-c cmd | -m mod | file | -]; try `apython --help'"
    call main_usage_error

.load_failed:
    ; A source file that failed to compile has a real SyntaxError pending, with
    ; a line number in it; saying "failed to load" instead would throw that
    ; away.  Nothing has run yet, so there is no traceback to print.
    mov rdi, [rel current_exception]
    test rdi, rdi
    jz .load_failed_plain
    ; Whatever is waiting on stdout goes out before the report does.  CPython
    ; flushes both streams in flush_io() on its way into the display routine,
    ; and it is what puts a program's output ahead of the traceback that ended
    ; it rather than after: the two streams are buffered differently, so
    ; without this the order through a pipe came out inverted.  The unraisable
    ; hook does NOT do it -- CPython's does not either.
    push rdi
    extern fileobj_flush_std
    call fileobj_flush_std
    pop rdi
    call traceback_print
    mov rdi, [rel current_exception]
    call obj_decref
    mov qword [rel current_exception], 0
    ; .exit_cleanup DECREFs the globals dict and the code object, and at this
    ; point neither exists -- nothing has been loaded yet.  Return straight out
    ; with the status instead.
    mov eax, 1
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
.load_failed_plain:
    CSTRING rdi, "Error: failed to load file"
    call fatal_error
END_FUNC main

;; ============================================================================
;; main_usage_error(rdi = the message) -> does not return; exits 2
;;
;; fatal_error's own status is 1, which is right for an interpreter that
;; started and could not go on.  A command line it could not parse is
;; CPython's exit 2, and the difference matters to a caller that distinguishes
;; a bad invocation from a program that ran and failed.
;; ============================================================================
DEF_FUNC_LOCAL main_usage_error, 8   ; + 1 push = 16, 16-aligned
    push rdi
    mov edi, 2
    CSTRING rsi, "Error: "
    mov edx, 7
    extern sys_write
    call sys_write
    pop rdi
    push rdi
    call ap_strlen
    mov rdx, rax
    pop rsi
    mov edi, 2
    call sys_write
    mov edi, 2
    lea rsi, [rel main_nl]
    mov edx, 1
    call sys_write
    mov edi, 2
    extern sys_exit_now
    call sys_exit_now
    ud2
END_FUNC main_usage_error

;; ============================================================================
;; main_read_stdin() -> rax = a NUL-terminated buffer, or 0
;;
;; The whole of standard input, for `apython -`.  It is read rather than
;; mapped because stdin is as likely to be a pipe as a file, and grown by
;; doubling because a pipe cannot be sized in advance.  The buffer is never
;; freed: it lives as long as the program compiled from it, which is as long
;; as the process.
;; ============================================================================
MRS_BUF  equ 8
MRS_CAP  equ 16
MRS_LEN  equ 24
MRS_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
DEF_FUNC_LOCAL main_read_stdin, MRS_FRAME
    mov edi, 65536
    mov [rbp - MRS_CAP], rdi
    extern ap_malloc
    call ap_malloc
    test rax, rax
    jz .mrs_fail
    mov [rbp - MRS_BUF], rax
    mov qword [rbp - MRS_LEN], 0
.mrs_loop:
    ; Always leave one byte for the terminator.
    mov rdx, [rbp - MRS_CAP]
    sub rdx, [rbp - MRS_LEN]
    dec rdx
    test rdx, rdx
    jg .mrs_have_room
    mov rdi, [rbp - MRS_BUF]
    mov rsi, [rbp - MRS_CAP]
    shl rsi, 1
    mov [rbp - MRS_CAP], rsi
    extern ap_realloc
    call ap_realloc
    test rax, rax
    jz .mrs_fail
    mov [rbp - MRS_BUF], rax
    jmp .mrs_loop
.mrs_have_room:
    mov rsi, [rbp - MRS_BUF]
    add rsi, [rbp - MRS_LEN]
    xor edi, edi                ; fd 0
    extern sys_read
    call sys_read
    test rax, rax
    jl .mrs_fail
    jz .mrs_done
    add [rbp - MRS_LEN], rax
    jmp .mrs_loop
.mrs_done:
    mov rax, [rbp - MRS_BUF]
    mov rcx, [rbp - MRS_LEN]
    mov byte [rax + rcx], 0
    mov [rel stdin_buf], rax
    leave
    ret
.mrs_fail:
    xor eax, eax
    leave
    ret
END_FUNC main_read_stdin

;; ============================================================================
;; main_sys_options() -> nothing; sys.warnoptions and sys._xoptions filled
;;
;; In CPython's order: "default" for -X dev, then PYTHONWARNINGS (unless -E),
;; then each -W, then -b's BytesWarning; warnings.py reads the list at import.
;; Each -X is a _xoptions key, holding the text after "=", or True.
;; ============================================================================
MSO_LIST  equ 8
MSO_XDICT equ 16
MSO_I     equ 24
MSO_CUR   equ 32
MSO_KEY   equ 40
MSO_FRAME equ 48
DEF_FUNC main_sys_options, MSO_FRAME
    extern sys_module_obj
    extern dict_get
    extern list_append
    extern str_new_heap
    mov rax, [rel sys_module_obj]
    mov rax, [rax + PyModuleObject.mod_dict]
    mov [rbp - MSO_XDICT], rax          ; the sys dict, briefly
    CSTRING rdi, "_xoptions"
    call str_from_cstr_heap
    mov [rbp - MSO_KEY], rax
    mov rdi, [rbp - MSO_XDICT]
    mov rsi, rax
    call dict_get
    mov [rbp - MSO_CUR], rax
    mov rdi, [rbp - MSO_KEY]
    call obj_decref
    CSTRING rdi, "warnoptions"
    call str_from_cstr_heap
    mov [rbp - MSO_KEY], rax
    mov rdi, [rbp - MSO_XDICT]
    mov rsi, rax
    call dict_get
    mov [rbp - MSO_LIST], rax
    mov rdi, [rbp - MSO_KEY]
    call obj_decref
    mov rax, [rbp - MSO_CUR]
    mov [rbp - MSO_XDICT], rax
    cmp qword [rbp - MSO_LIST], 0
    je .mso_out
    cmp qword [rbp - MSO_XDICT], 0
    je .mso_out

    cmp byte [rel main_sysflags + SF_DEV_MODE], 0
    je .mso_env
    mov rdi, [rbp - MSO_LIST]
    CSTRING rsi, "default"
    call mso_append_cstr

.mso_env:
    cmp byte [rel main_sysflags + SF_IGNORE_ENV], 0
    jne .mso_w
    CSTRING rdi, "PYTHONWARNINGS"
    call getenv
    test rax, rax
    jz .mso_w
    mov [rbp - MSO_CUR], rax
.mso_env_item:
    mov rdi, [rbp - MSO_CUR]
    xor ecx, ecx
.mso_env_len:
    movzx eax, byte [rdi + rcx]
    test al, al
    jz .mso_env_have
    cmp al, ','
    je .mso_env_have
    inc rcx
    jmp .mso_env_len
.mso_env_have:
    mov [rbp - MSO_I], rcx
    test rcx, rcx
    jz .mso_env_next                    ; an empty item is skipped
    mov rsi, rcx
    call str_new_heap
    mov rdi, [rbp - MSO_LIST]
    mov rsi, rax
    call mso_append_owned
.mso_env_next:
    mov rax, [rbp - MSO_CUR]
    add rax, [rbp - MSO_I]
    cmp byte [rax], 0
    je .mso_w
    inc rax
    mov [rbp - MSO_CUR], rax
    jmp .mso_env_item

.mso_w:
    mov qword [rbp - MSO_I], 0
.mso_w_loop:
    mov rax, [rbp - MSO_I]
    cmp rax, [rel main_wopt_count]
    jae .mso_b
    lea rcx, [rel main_wopts]
    mov rsi, [rcx + rax * 8]
    mov rdi, [rbp - MSO_LIST]
    call mso_append_cstr
    inc qword [rbp - MSO_I]
    jmp .mso_w_loop

.mso_b:
    movzx eax, byte [rel main_sysflags + SF_BYTES_WARNING]
    test eax, eax
    jz .mso_x
    CSTRING rsi, "default::BytesWarning"
    cmp eax, 1
    je .mso_b_add
    CSTRING rsi, "error::BytesWarning"
.mso_b_add:
    mov rdi, [rbp - MSO_LIST]
    call mso_append_cstr

.mso_x:
    mov qword [rbp - MSO_I], 0
.mso_x_loop:
    mov rax, [rbp - MSO_I]
    cmp rax, [rel main_xopt_count]
    jae .mso_out
    lea rcx, [rel main_xopts]
    mov rdi, [rcx + rax * 8]
    mov [rbp - MSO_CUR], rdi
    ; key up to "=", the value after it or True
    xor ecx, ecx
.mso_x_scan:
    movzx eax, byte [rdi + rcx]
    test al, al
    jz .mso_x_have
    cmp al, '='
    je .mso_x_have
    inc rcx
    jmp .mso_x_scan
.mso_x_have:
    mov rsi, rcx
    push rcx
    sub rsp, 8
    call str_new_heap
    add rsp, 8
    pop rcx
    mov [rbp - MSO_KEY], rax
    mov rdi, [rbp - MSO_CUR]
    cmp byte [rdi + rcx], '='
    jne .mso_x_true
    lea rdi, [rdi + rcx + 1]
    call str_from_cstr_heap
    jmp .mso_x_store
.mso_x_true:
    extern bool_true
    lea rax, [rel bool_true]
    INCREF rax
.mso_x_store:
    mov [rbp - MSO_CUR], rax
    mov rdi, [rbp - MSO_XDICT]
    mov rsi, [rbp - MSO_KEY]
    mov rdx, rax
    call dict_set
    mov rdi, [rbp - MSO_KEY]
    call obj_decref
    mov rdi, [rbp - MSO_CUR]
    call obj_decref
    inc qword [rbp - MSO_I]
    jmp .mso_x_loop
.mso_out:
    leave
    ret

END_FUNC main_sys_options

;; ============================================================================
;; mso_append_cstr(rdi = list, rsi = C string) -> nothing
;; ============================================================================
MAC_LIST  equ 8
MAC_STR   equ 16
MAC_FRAME equ 16
DEF_FUNC_LOCAL mso_append_cstr, MAC_FRAME
    mov [rbp - MAC_LIST], rdi
    mov rdi, rsi
    call str_from_cstr_heap
    mov rdi, [rbp - MAC_LIST]
    mov rsi, rax
    call mso_append_owned
    leave
    ret
END_FUNC mso_append_cstr

;; ============================================================================
;; mso_append_owned(rdi = list, rsi = str, owned) -> nothing; reference spent
;; ============================================================================
DEF_FUNC_LOCAL mso_append_owned, MAC_FRAME
    mov [rbp - MAC_STR], rsi
    call list_append
    mov rdi, [rbp - MAC_STR]
    call obj_decref
    leave
    ret
END_FUNC mso_append_owned

;; ============================================================================
;; main_env_flags() -> nothing; main_sysflags updated from the environment
;;
;; PYTHONNOUSERSITE, PYTHONSAFEPATH and PYTHONDONTWRITEBYTECODE, each set
;; when the variable is set and not empty -- unless -E or -I said the
;; environment is not to be consulted.
;; ============================================================================
DEF_FUNC main_env_flags
    cmp byte [rel main_sysflags + SF_IGNORE_ENV], 0
    jne .mef_out
    CSTRING rdi, "PYTHONNOUSERSITE"
    call main_env_set
    jz .mef_safe
    mov byte [rel main_sysflags + SF_NO_USER_SITE], 1
.mef_safe:
    CSTRING rdi, "PYTHONSAFEPATH"
    call main_env_set
    jz .mef_bc
    mov byte [rel main_sysflags + SF_SAFE_PATH], 1
.mef_bc:
    CSTRING rdi, "PYTHONDONTWRITEBYTECODE"
    call main_env_set
    jz .mef_out
    mov byte [rel main_sysflags + SF_DONT_WRITE_BC], 1
    mov byte [rel main_no_bytecode], 1
.mef_out:
    leave
    ret
END_FUNC main_env_flags

;; ============================================================================
;; main_env_set(rdi = variable name) -> ZF clear when it is set and non-empty
;; ============================================================================
DEF_FUNC main_env_set
    extern getenv
    call getenv
    test rax, rax
    jz .mes_out
    cmp byte [rax], 0
.mes_out:
    leave
    ret
END_FUNC main_env_set

;; ============================================================================
;; main_run_startup(rdi = source, rsi = its length)
;;   -> eax = 0, or 1 with the exception in current_exception
;;
;; One startup statement -- `import site` and the like -- compiled and run in
;; a frame of its own with a namespace of its own, so that the binding lands
;; nowhere a program can see: CPython imports these from C and binds no name.
;; ============================================================================
MIS_CODE  equ 8
MIS_DICT  equ 16
MIS_SRC   equ 24
MIS_LEN   equ 32
MIS_FRAME equ 32
DEF_FUNC main_run_startup, MIS_FRAME
    mov [rbp - MIS_SRC], rdi
    mov [rbp - MIS_LEN], rsi
    extern str_from_cstr_heap
    CSTRING rdi, "<startup>"
    call str_from_cstr_heap
    mov [rbp - MIS_DICT], rax         ; the filename, briefly
    mov rdi, [rbp - MIS_SRC]
    mov rsi, [rbp - MIS_LEN]
    mov rdx, rax
    mov ecx, CMODE_EXEC
    extern compile_source
    call compile_source
    mov [rbp - MIS_CODE], rax
    mov rdi, [rbp - MIS_DICT]
    call obj_decref
    cmp qword [rbp - MIS_CODE], 0
    je .mis_failed

    call dict_new
    mov [rbp - MIS_DICT], rax
    extern builtins_dict_global
    lea rdi, [rel __builtins__cstr]
    call str_from_cstr_heap
    push rax
    sub rsp, 8
    mov rdi, [rbp - MIS_DICT]
    mov rsi, rax
    mov rdx, [rel builtins_dict_global]
    call dict_set
    add rsp, 8
    pop rdi
    call obj_decref

    mov rdi, [rbp - MIS_CODE]
    mov rsi, [rbp - MIS_DICT]
    mov rdx, [rel builtins_dict_global]
    mov rcx, [rbp - MIS_DICT]
    call frame_new
    push rax
    sub rsp, 8
    mov rdi, rax
    call eval_frame
    V_UNPACK rax, rdx
    add rsp, 8
    pop rdi
    call frame_free
    mov rdi, [rbp - MIS_DICT]
    call obj_decref
    mov rdi, [rbp - MIS_CODE]
    call obj_decref

    extern current_exception
    xor eax, eax
    cmp qword [rel current_exception], 0
    je .mis_out
.mis_failed:
    mov eax, 1
.mis_out:
    leave
    ret
END_FUNC main_run_startup

section .rodata
; The single-letter flags accepted: -E -I -S -s -B -u -b -d -q -v -O -P -R,
; and any repetition of them (-OO, -bb, -vv).  Each that has a field in
; sys.flags is counted there (main_flag_chars below); -E, -s, -S, -I and -P
; change what startup does, and the rest are reported but switch off
; machinery apython does not have.  An unknown flag is refused outright.
main_noop_flags: db "EISBubdqvOPRs", 0
; The flags that are a field of sys.flags, and that field's index.
main_flag_chars: db "dOBsSEvbqP", 0
main_flag_index: db SF_DEBUG, SF_OPTIMIZE, SF_DONT_WRITE_BC, SF_NO_USER_SITE
                 db SF_NO_SITE, SF_IGNORE_ENV, SF_VERBOSE, SF_BYTES_WARNING
                 db SF_QUIET, SF_SAFE_PATH
main_nl: db 10

section .bss
global main_no_bytecode
main_no_bytecode: resb 1
global main_sysflags
main_sysflags: resb SYSFLAGS_COUNT     ; sys.flags, by SF_ index (macros.inc)
MAIN_OPT_MAX equ 32
alignb 8
main_wopts: resq MAIN_OPT_MAX          ; each -W argument, in order
main_wopt_count: resq 1
main_xopts: resq MAIN_OPT_MAX          ; each -X argument, in order
main_xopt_count: resq 1

section .rodata

; What -m runs.  The module name is in sys.argv[0]; see the -m arm above.
main_runmodule_cmd: db "import _runmodule; _runmodule.run()", 0

section .bss
global main_orig_argc
global main_orig_argv
; argc and argv as the process received them, for sys.orig_argv.
main_orig_argc: resq 1
main_orig_argv: resq 1
; The -c command, the -m bootstrap, or the text read from stdin; 0 when a
; file was named.
cmd_source: resq 1
; 1 when cmd_source came from standard input, which only changes the filename
; the traceback shows.
cmd_is_stdin: resq 1
; The stdin text, kept so it is not freed while the compile reads it.
stdin_buf: resq 1

section .rodata
help_flag: db "--help", 0
help_short_flag: db "-h", 0
help_q_flag: db "-?", 0
help_msg:
    db "usage: apython [option] ... [-c cmd | -m mod | file | -] [arg] ...", 10
    db "Options:", 10
    db "-h     : print this help message and exit (also -? or --help)", 10
    db "-c <cmd> : run the string <cmd> as a program", 10
    db "-m <mod> : run the module <mod> as __main__", 10
    db "-        : run the program read from standard input", 10
    db "-t     : trace opcodes (partial: DISPATCH-terminated handlers are", 10
    db "         not traced -- see bugs.md)", 10
    db "--version : print the apython version number and exit", 10
    db "--dis [-x] <source> : print the bytecode compiled from <source>;", 10
    db "         -x compiles in exec mode rather than eval mode", 10
    db "--selftest-value : run the Value encoding self-test and exit", 10
    db "--selftest-compile : run the source compiler self-test and exit", 10
    db "--selftest-alloc : run the pool allocator self-test and exit", 10
    db 10
    db "Arguments:", 10
    db "file   : a .py file to compile and run, or a .pyc file to run directly", 10
help_msg_len equ $ - help_msg

selftest_flag: db "--selftest-value", 0
selftest_compile_flag: db "--selftest-compile", 0
selftest_alloc_flag: db "--selftest-alloc", 0
dis_flag: db "--dis", 0
version_msg: db "apython ", VERSION_STR, 10
version_msg_len equ $ - version_msg
__name__cstr: db "__name__", 0
__doc__cstr: db "__doc__", 0
__main__cstr: db "__main__", 0
__package__cstr: db "__package__", 0
__file__cstr: db "__file__", 0
__builtins__cstr: db "__builtins__", 0
newline_char: db 10
