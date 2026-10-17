; pathconfig.asm - where the interpreter finds itself, and its library
;
; CPython's getpath: before the first import, work out which installation this
; binary belongs to, and from that the prefix, the standard library, the
; directory beside it that holds what stands in for C modules, and what
; sys.executable should say.  Everything here is computed once, into fixed
; buffers, and read by import_init (sys.path) and sys_module_init (sys.prefix
; and friends).  No object is built and nothing can raise: this runs before
; there is anything to raise into.
;
; Two layouts are recognised, by a landmark each, and the first that answers
; wins:
;
;   build tree    <dir of binary>/stdlib/os.py
;                 stdlib  = <dir>/stdlib      CPython's Lib/, unmodified
;                 dynload = <dir>/lib         the stand-ins for C modules
;                 extra   = <dir>/tests/cpython
;                 prefix  = <dir>
;
;   installed     <prefix>/lib/python3.12/os.py, <prefix> = the binary's
;                 directory's parent -- CPython's own layout, names and all,
;                 because site.py, sysconfig, venv and pip each build paths
;                 from those names and none of them would find anything else
;                 stdlib  = <prefix>/lib/python3.12
;                 dynload = <prefix>/lib/python3.12/lib-dynload
;
; The binary is located through /proc/self/exe, which resolves symlinks: a
; venv's bin/python is a symlink to the real interpreter, so the library is
; found from the real one while sys.executable keeps the venv's path, and
; site.py takes the venv from there exactly as it does under CPython.
;
; sys.executable is NOT the resolved path, for that reason.  It is argv[0]
; made absolute when it has a slash in it, and otherwise the first PATH entry
; holding an executable of that name -- which is what CPython does, and what
; puts a venv's bin/ directory in it.

%include "macros.inc"

extern exe_path
extern getenv
extern main_orig_argv
extern sys_access
extern sys_getcwd
extern sys_stat

PC_MAX   equ 4096               ; every buffer here, NUL included
F_OK     equ 0
X_OK     equ 1
S_IFMT   equ 0o170000
S_IFREG  equ 0o100000
ST_MODE  equ 24                 ; struct stat.st_mode on x86-64

section .bss
global pc_executable, pc_prefix, pc_stdlib, pc_dynload, pc_extra
pc_executable: resb PC_MAX      ; sys.executable
pc_prefix:     resb PC_MAX      ; sys.prefix, and the base_ and exec_ ones
pc_stdlib:     resb PC_MAX      ; CPython's Lib/
pc_dynload:    resb PC_MAX      ; lib/, the stand-ins for C modules
pc_extra:      resb PC_MAX      ; tests/cpython in a build tree, else empty
pc_tmp:        resb PC_MAX      ; scratch for the probes
pc_script:     resb PC_MAX      ; the main script, made absolute

section .text

;; ============================================================================
;; pc_append(rdi = NUL-terminated buffer of PC_MAX bytes,
;;           rsi = C string) -> rax = the new length
;;
;; Appends as much of the string as fits, always leaving the buffer
;; terminated.  A path that does not fit is truncated rather than overrun; it
;; then fails whatever probe it is for, which is the right answer for a path
;; longer than PATH_MAX anyway.
;; ============================================================================
DEF_FUNC_BARE pc_append
    xor eax, eax
.pa_end:
    cmp byte [rdi + rax], 0
    je .pa_copy
    inc rax
    jmp .pa_end
.pa_copy:
    movzx ecx, byte [rsi]
    test cl, cl
    jz .pa_done
    cmp rax, PC_MAX - 1
    jae .pa_done
    mov [rdi + rax], cl
    inc rax
    inc rsi
    jmp .pa_copy
.pa_done:
    mov byte [rdi + rax], 0
    ret
END_FUNC pc_append

;; ============================================================================
;; pc_set(rdi = buffer of PC_MAX bytes, rsi = C string) -> rax = the length
;;
;; The buffer becomes a copy of the string.
;; ============================================================================
DEF_FUNC_BARE pc_set
    mov byte [rdi], 0
    jmp pc_append
END_FUNC pc_set

;; ============================================================================
;; pc_dirname(rdi = NUL-terminated path) -> nothing; truncated in place
;;
;; "/a/b/c" becomes "/a/b", "/c" becomes "/", and a path with no slash at all
;; becomes empty.
;; ============================================================================
DEF_FUNC_BARE pc_dirname
    xor eax, eax
    mov rcx, -1                 ; index of the last '/'
.pd_scan:
    movzx edx, byte [rdi + rax]
    test dl, dl
    jz .pd_cut
    cmp dl, '/'
    jne .pd_next
    mov rcx, rax
.pd_next:
    inc rax
    jmp .pd_scan
.pd_cut:
    test rcx, rcx
    js .pd_empty
    jnz .pd_at
    mov byte [rdi + 1], 0       ; the slash is the root: keep it
    ret
.pd_at:
    mov byte [rdi + rcx], 0
    ret
.pd_empty:
    mov byte [rdi], 0
    ret
END_FUNC pc_dirname

;; ============================================================================
;; pc_is_file(rdi = path) -> eax = 1 when it names a regular file, else 0
;; ============================================================================
PIF_STAT  equ 144               ; struct stat
PIF_FRAME equ 144
DEF_FUNC pc_is_file, PIF_FRAME
    lea rsi, [rbp - PIF_STAT]
    call sys_stat
    test rax, rax
    jnz .pif_no
    mov eax, [rbp - PIF_STAT + ST_MODE]
    and eax, S_IFMT
    cmp eax, S_IFREG
    jne .pif_no
    mov eax, 1
    leave
    ret
.pif_no:
    xor eax, eax
    leave
    ret
END_FUNC pc_is_file

;; ============================================================================
;; pc_normalize(rdi = NUL-terminated absolute path) -> nothing; in place
;;
;; os.path.normpath for a path that starts with '/': empty and "." components
;; are dropped, ".." removes the one before it and never climbs past the
;; root.  Symlinks are left alone, as abspath leaves them.  The result is never
;; longer than the input, so it is built over it.
;; ============================================================================
DEF_FUNC_BARE pc_normalize
    mov rsi, rdi                ; read cursor
    mov rdx, rdi                ; write cursor; [rdi] stays the root '/'
.pn_component:
    ; Skip slashes.
    cmp byte [rsi], '/'
    jne .pn_have
    inc rsi
    jmp .pn_component
.pn_have:
    cmp byte [rsi], 0
    je .pn_finish
    ; Measure the component.
    xor ecx, ecx
.pn_len:
    movzx eax, byte [rsi + rcx]
    test al, al
    jz .pn_measured
    cmp al, '/'
    je .pn_measured
    inc rcx
    jmp .pn_len
.pn_measured:
    cmp rcx, 1
    jne .pn_not_dot
    cmp byte [rsi], '.'
    jne .pn_copy
    add rsi, rcx                ; "."
    jmp .pn_component
.pn_not_dot:
    cmp rcx, 2
    jne .pn_copy
    cmp word [rsi], '..'
    jne .pn_copy
    ; "..": back the write cursor up to the previous slash, not past the root.
    add rsi, rcx
.pn_up:
    cmp rdx, rdi
    je .pn_component
    dec rdx
    cmp byte [rdx], '/'
    jne .pn_up
    jmp .pn_component
.pn_copy:
    mov byte [rdx], '/'
    inc rdx
.pn_copy_byte:
    test rcx, rcx
    jz .pn_component
    mov al, [rsi]
    mov [rdx], al
    inc rsi
    inc rdx
    dec rcx
    jmp .pn_copy_byte
.pn_finish:
    cmp rdx, rdi
    jne .pn_term
    mov byte [rdx], '/'         ; everything collapsed: the root
    inc rdx
.pn_term:
    mov byte [rdx], 0
    ret
END_FUNC pc_normalize

;; ============================================================================
;; pc_abspath(rdi = buffer of PC_MAX bytes, rsi = path) -> nothing
;;
;; os.path.abspath: the working directory joined to a relative path, and
;; either kind normalised.  The buffer must not be the path.
;; ============================================================================
PAB_DST   equ 8
PAB_SRC   equ 16
PAB_FRAME equ 16
DEF_FUNC pc_abspath, PAB_FRAME
    mov [rbp - PAB_DST], rdi
    mov [rbp - PAB_SRC], rsi
    cmp byte [rsi], '/'
    jne .pab_relative
    call pc_set
    jmp .pab_norm
.pab_relative:
    mov esi, PC_MAX - 2
    call sys_getcwd
    test rax, rax
    js .pab_no_cwd
    mov rdi, [rbp - PAB_DST]
    CSTRING rsi, "/"
    call pc_append
    mov rdi, [rbp - PAB_DST]
    mov rsi, [rbp - PAB_SRC]
    call pc_append
    jmp .pab_norm
.pab_no_cwd:
    ; No working directory to resolve against: the path as given is the best
    ; there is, and normalising a relative one would make it wrong.
    mov rdi, [rbp - PAB_DST]
    mov rsi, [rbp - PAB_SRC]
    call pc_set
    leave
    ret
.pab_norm:
    mov rdi, [rbp - PAB_DST]
    call pc_normalize
    leave
    ret
END_FUNC pc_abspath

;; ============================================================================
;; pc_try_layout(rdi = candidate prefix, rsi = stdlib suffix,
;;               rdx = dynload suffix, rcx = extra suffix or 0)
;;   -> eax = 1 when the layout's landmark exists, and the four buffers set
;;
;; The landmark is os.py in the candidate stdlib directory, CPython's own.
;; ============================================================================
PTL_PREFIX equ 8
PTL_STDLIB equ 16
PTL_DYN    equ 24
PTL_EXTRA  equ 32
PTL_FRAME  equ 32
DEF_FUNC pc_try_layout, PTL_FRAME
    mov [rbp - PTL_PREFIX], rdi
    mov [rbp - PTL_STDLIB], rsi
    mov [rbp - PTL_DYN], rdx
    mov [rbp - PTL_EXTRA], rcx

    mov rsi, rdi
    lea rdi, [rel pc_tmp]
    call pc_set
    lea rdi, [rel pc_tmp]
    mov rsi, [rbp - PTL_STDLIB]
    call pc_append
    lea rdi, [rel pc_tmp]
    CSTRING rsi, "/os.py"
    call pc_append
    lea rdi, [rel pc_tmp]
    call pc_is_file
    test eax, eax
    jz .ptl_out

    lea rdi, [rel pc_stdlib]
    mov rsi, [rbp - PTL_PREFIX]
    call pc_set
    lea rdi, [rel pc_stdlib]
    mov rsi, [rbp - PTL_STDLIB]
    call pc_append

    lea rdi, [rel pc_dynload]
    mov rsi, [rbp - PTL_PREFIX]
    call pc_set
    lea rdi, [rel pc_dynload]
    mov rsi, [rbp - PTL_DYN]
    call pc_append

    mov byte [rel pc_extra], 0
    cmp qword [rbp - PTL_EXTRA], 0
    je .ptl_prefix
    lea rdi, [rel pc_extra]
    mov rsi, [rbp - PTL_PREFIX]
    call pc_set
    lea rdi, [rel pc_extra]
    mov rsi, [rbp - PTL_EXTRA]
    call pc_append

.ptl_prefix:
    ; Last, because the candidate may BE pc_prefix's own contents.
    lea rdi, [rel pc_tmp]
    mov rsi, [rbp - PTL_PREFIX]
    call pc_set
    lea rdi, [rel pc_prefix]
    lea rsi, [rel pc_tmp]
    call pc_set
    mov eax, 1
.ptl_out:
    leave
    ret
END_FUNC pc_try_layout

;; ============================================================================
;; pc_find_executable(rdi = argv[0]) -> nothing; pc_executable set
;;
;; A name with a slash in it is a path, made absolute.  A bare name is looked
;; up on PATH, the first entry holding an executable regular file of that name
;; winning; an empty entry is the working directory.  When neither answers --
;; no PATH, or a name that is not on it -- the resolved binary is the answer,
;; which is still a path that runs this interpreter.
;; ============================================================================
PFE_NAME  equ 8
PFE_CUR   equ 16                ; cursor into PATH
PFE_FRAME equ 16
DEF_FUNC pc_find_executable, PFE_FRAME
    mov [rbp - PFE_NAME], rdi
    test rdi, rdi
    jz .pfe_fallback
    cmp byte [rdi], 0
    je .pfe_fallback
    mov rsi, rdi
.pfe_slash:
    movzx eax, byte [rsi]
    test al, al
    jz .pfe_search
    cmp al, '/'
    je .pfe_path
    inc rsi
    jmp .pfe_slash

.pfe_path:
    lea rdi, [rel pc_executable]
    mov rsi, [rbp - PFE_NAME]
    call pc_abspath
    leave
    ret

.pfe_search:
    CSTRING rdi, "PATH"
    call getenv
    test rax, rax
    jz .pfe_fallback
    mov [rbp - PFE_CUR], rax
.pfe_entry:
    ; pc_tmp = the entry, or "." for an empty one; then "/" and the name.
    mov rsi, [rbp - PFE_CUR]
    lea rdi, [rel pc_tmp]
    xor ecx, ecx
.pfe_copy:
    movzx eax, byte [rsi + rcx]
    test al, al
    jz .pfe_copied
    cmp al, ':'
    je .pfe_copied
    cmp rcx, PC_MAX - 2
    jae .pfe_skip
    mov [rdi + rcx], al
    inc rcx
    jmp .pfe_copy
.pfe_copied:
    test rcx, rcx
    jnz .pfe_have_dir
    mov byte [rdi], '.'
    inc rcx
.pfe_have_dir:
    mov byte [rdi + rcx], 0
    add [rbp - PFE_CUR], rcx    ; past the entry ...
    cmp byte [rel pc_tmp], '.'  ; ... which "." was not a character of
    jne .pfe_join
    cmp byte [rel pc_tmp + 1], 0
    jne .pfe_join
    mov rax, [rbp - PFE_CUR]
    cmp byte [rax - 1], '.'
    je .pfe_join
    dec qword [rbp - PFE_CUR]   ; the empty entry consumed nothing
.pfe_join:
    lea rdi, [rel pc_tmp]
    CSTRING rsi, "/"
    call pc_append
    lea rdi, [rel pc_tmp]
    mov rsi, [rbp - PFE_NAME]
    call pc_append
    lea rdi, [rel pc_tmp]
    call pc_is_file
    test eax, eax
    jz .pfe_next
    lea rdi, [rel pc_tmp]
    mov esi, X_OK
    call sys_access
    test rax, rax
    jnz .pfe_next
    lea rdi, [rel pc_executable]
    lea rsi, [rel pc_tmp]
    call pc_abspath
    leave
    ret
.pfe_skip:
    ; An entry longer than a path can be: step over it whole.
    mov rsi, [rbp - PFE_CUR]
.pfe_skip_byte:
    movzx eax, byte [rsi]
    test al, al
    jz .pfe_fallback
    cmp al, ':'
    je .pfe_skipped
    inc rsi
    jmp .pfe_skip_byte
.pfe_skipped:
    mov [rbp - PFE_CUR], rsi
.pfe_next:
    mov rax, [rbp - PFE_CUR]
    cmp byte [rax], 0
    je .pfe_fallback
    inc qword [rbp - PFE_CUR]   ; the ':'
    jmp .pfe_entry

.pfe_fallback:
    lea rdi, [rel pc_executable]
    mov esi, PC_MAX - 1
    call exe_path
    lea rcx, [rel pc_executable]
    mov byte [rcx + rax], 0
    leave
    ret
END_FUNC pc_find_executable

;; ============================================================================
;; pathconfig_init() -> nothing; the five pc_ buffers set
;;
;; Called once, from import_init, before sys or sys.path exists.
;; ============================================================================
PCI_DIR   equ PC_MAX            ; the binary's directory
PCI_FRAME equ PC_MAX
DEF_FUNC pathconfig_init, PCI_FRAME
    lea rdi, [rbp - PCI_DIR]
    mov esi, PC_MAX - 1
    call exe_path
    lea rdi, [rbp - PCI_DIR]
    mov byte [rdi + rax], 0
    call pc_dirname

    ; The build tree.
    lea rdi, [rbp - PCI_DIR]
    CSTRING rsi, "/stdlib"
    CSTRING rdx, "/lib"
    CSTRING rcx, "/tests/cpython"
    call pc_try_layout
    test eax, eax
    jnz .pci_exe

    ; An installation: the library is under the parent of bin/.
    lea rdi, [rbp - PCI_DIR]
    call pc_dirname
    lea rdi, [rbp - PCI_DIR]
    CSTRING rsi, "/lib/python3.12"
    CSTRING rdx, "/lib/python3.12/lib-dynload"
    xor ecx, ecx
    call pc_try_layout
    test eax, eax
    jnz .pci_exe

    ; Neither: the binary's own directory, laid out as a build tree, which is
    ; what every apython before this file assumed.  Imports beyond the
    ; builtins will fail, and say which module they could not find.
    lea rdi, [rbp - PCI_DIR]
    mov esi, PC_MAX - 1
    call exe_path
    lea rdi, [rbp - PCI_DIR]
    mov byte [rdi + rax], 0
    call pc_dirname
    lea rdi, [rel pc_prefix]
    lea rsi, [rbp - PCI_DIR]
    call pc_set
    lea rdi, [rel pc_stdlib]
    lea rsi, [rbp - PCI_DIR]
    call pc_set
    lea rdi, [rel pc_stdlib]
    CSTRING rsi, "/stdlib"
    call pc_append
    lea rdi, [rel pc_dynload]
    lea rsi, [rbp - PCI_DIR]
    call pc_set
    lea rdi, [rel pc_dynload]
    CSTRING rsi, "/lib"
    call pc_append
    mov byte [rel pc_extra], 0

.pci_exe:
    xor edi, edi
    mov rax, [rel main_orig_argv]
    test rax, rax
    jz .pci_have_argv0
    mov rdi, [rax]
.pci_have_argv0:
    call pc_find_executable
    leave
    ret
END_FUNC pathconfig_init

;; ============================================================================
;; pathconfig_script(rdi = the script path as given) -> rax = C string
;;
;; The main script's path, made absolute, as CPython has done since 3.9: it
;; is __file__, the co_filename every traceback prints, and what sys.path[0]
;; is the directory of.  The buffer is static and lives as long as the
;; process.
;; ============================================================================
DEF_FUNC pathconfig_script
    mov rsi, rdi
    lea rdi, [rel pc_script]
    call pc_abspath
    lea rax, [rel pc_script]
    leave
    ret
END_FUNC pathconfig_script

;; ============================================================================
;; pathconfig_cwd_dir() -> rax = C string: the working directory, then "/"
;;
;; What -m puts at sys.path[0] is the working directory itself.  Handed to
;; sys_path_add_script_dir, which keeps everything before the last slash,
;; the trailing slash is what makes that the whole directory.
;; ============================================================================
DEF_FUNC pathconfig_cwd_dir
    lea rdi, [rel pc_script]
    CSTRING rsi, "."
    call pc_abspath
    lea rdi, [rel pc_script]
    CSTRING rsi, "/"
    call pc_append
    lea rax, [rel pc_script]
    leave
    ret
END_FUNC pathconfig_cwd_dir

section .bss
pc_path0: resb PC_MAX           ; what sys.path[0] is the directory of
section .text

;; ============================================================================
;; pathconfig_path0(rdi = the absolute script path) -> rax = C string
;;
;; The path sys.path[0] is the directory of.  A script that is a .pyc in a
;; __pycache__ directory -- `apython pkg/__pycache__/m.cpython-312.pyc` -- is
;; treated as the source beside it would be: the modules it imports live in
;; pkg/, and importlib, like CPython's, never imports from __pycache__ by a
;; bare name.  Anything else is the path unchanged.
;; ============================================================================
PP0_SRC   equ 8
PP0_FRAME equ 16
DEF_FUNC pathconfig_path0, PP0_FRAME
    mov [rbp - PP0_SRC], rdi
    mov rsi, rdi
    lea rdi, [rel pc_path0]
    call pc_set
    lea rdi, [rel pc_path0]
    call pc_dirname                 ; .../__pycache__, or not
    lea rdi, [rel pc_path0]
    xor eax, eax
.pp0_end:
    cmp byte [rdi + rax], 0
    je .pp0_have_len
    inc rax
    jmp .pp0_end
.pp0_have_len:
    cmp rax, 12
    jb .pp0_unchanged
    lea rsi, [rdi + rax - 12]
    cmp byte [rsi], '/'
    jne .pp0_unchanged
    mov rcx, '__pycach'
    cmp [rsi + 1], rcx
    jne .pp0_unchanged
    cmp word [rsi + 9], 'e_'
    jne .pp0_unchanged
    cmp byte [rsi + 11], '_'
    jne .pp0_unchanged
    ; Drop "/__pycache__", keep a trailing "/x" so the caller's last-slash
    ; cut leaves the parent directory.
    mov byte [rsi], 0
    lea rdi, [rel pc_path0]
    CSTRING rsi, "/x"
    call pc_append
    lea rax, [rel pc_path0]
    leave
    ret
.pp0_unchanged:
    mov rax, [rbp - PP0_SRC]
    leave
    ret
END_FUNC pathconfig_path0
