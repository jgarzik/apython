; posixmod.asm - the `posix` module
;
; The platform module os.py imports.  It gates on
; `if 'posix' in sys.builtin_module_names`, so the name has to be in
; builtin_module_table (src/modules/table.asm) as well as in sys.modules; without
; that, os.py raises "no os specific module found" whatever else exists here.
;
; The surface is the one measured to make every stdlib module that currently
; fails on the missing platform module import: the file and directory calls
; os.py and os.path reach for, `environ`, `error`, `stat_result`, the O_*/S_*
; constants, and the wait/status family subprocess needs.
;
; Every syscall wrapper returns the kernel's own value -- the result, or
; -errno.  POSIX_CHECK turns the second into an OSError of the right subclass
; with the right filename, which is what makes `except FileNotFoundError`
; work rather than a bare OSError.
;
; Refcount discipline, which is where the bugs are:
;   - str_from_cstr_heap, str_new_heap and int_from_i64 return a FAT PAIR;
;     bytes_new, tuple_new, list_new and dict_new return a RAW POINTER;
;     list_append, dict_set and dict_get take VALUES.
;   - Anything out of V_PACK is released with DECREF_V, never obj_decref:
;     V_PACK boxes an int outside +-2^50 and hands back an owned reference,
;     while an immediate owns nothing.  Every st_size and st_mtime_ns hits
;     that under INT_STRESS=1.
;   - MODULE_ADD_FUNC requires the module dict in r12.

%include "macros.inc"
%include "object.inc"
extern posix_path_arg
%include "posixpath.inc"

ASM_INIT

extern ap_malloc
extern ap_free
extern ap_memcpy
extern ap_strlen
extern obj_decref
extern obj_dealloc
extern obj_incref
extern raise_exception
extern raise_oserror
extern raise_oserror_owned
extern raise_type_error_with_name
extern exc_TypeError_type
extern exc_ValueError_type
extern exc_OSError_type
extern str_from_cstr_heap
extern str_new_heap
extern str_type
extern bytes_from_data
extern bytes_type
extern bytearray_type
extern int_from_i64
extern float_from_f64
extern val_to_i64
extern int_is_integer
extern exc_OverflowError_type
extern int_fits_i64
extern list_new
extern list_append
extern dict_new
extern dict_set
extern tuple_new
extern module_new
extern builtin_func_new
extern none_singleton
extern bool_true
extern bool_false
extern type_type
extern structseq_new
extern structseq_set
extern structseq_init_type
extern structseq_repr
extern structseq_getattr
extern structseq_dealloc
extern dunder_call_1
extern value_type
extern strerror

extern sys_stat
extern sys_lstat
extern sys_fstat
extern sys_open
extern sys_close
extern sys_read
extern sys_write
extern sys_lseek
extern sys_dup
extern sys_getpid
extern sys_getcwd
extern sys_mkdir
extern sys_rmdir
extern sys_unlink
extern sys_rename
extern sys_readlink
extern sys_chmod
extern sys_access
extern sys_umask
extern sys_pipe2
extern sys_getdents64
extern sys_getrandom
extern sys_wait4
extern obj_as_index
extern obj_is_true
extern ap_strcmp
extern sys_uname
extern sys_ftruncate
extern sys_chdir
extern sys_truncate
extern sys_link
extern sys_chown
extern sys_fchmod
extern sys_fsync
extern posix_fork
; waitpid and the W* status readers live in posixproc.asm, with the rest of
; the process family -- posix.asm reached the 100k cap.
extern posix_waitpid
extern posix_waitstatus_to_exitcode
extern posix_wifexited
extern posix_wexitstatus
extern posix_wifsignaled
extern posix_wtermsig
extern posix_wifstopped
extern posix_wstopsig
extern posix_wifcontinued
extern posix_wcoredump
extern posix_execv
extern posix_close_range
extern posix_exit_now
extern posix_kill
extern posix_setsid
extern posix_register_at_fork
extern pm_atfork_before
extern pm_atfork_parent
extern pm_atfork_child
extern list_type
extern sys_fork
extern sys_execve
extern sys_exit_now
extern sys_kill
extern sys_setsid
extern sys_dup2
extern sys_utimensat
extern tuple_type
extern sys_fcntl
extern sys_ioctl

extern environ

section .text

;; ============================================================================
;; POSIX_CHECK reg, filename_value
;;
;; The kernel returns -errno in [-4095, -1] and the result otherwise.  As an
;; unsigned compare that is "at or above -4095", which is the standard test
;; and needs no sign handling.
;; ============================================================================
%macro POSIX_CHECK 2            ; %1 = the result register, %2 = filename Value
    cmp %1, -4095
    jb %%ok
    mov rdi, %1
    neg rdi
    mov rsi, %2
    call raise_oserror          ; does not return
%%ok:
%endmacro



;; ============================================================================
;; posix_name_object(rdi = a NUL-terminated C string, esi = 1 for bytes)
;;   -> rax = a str or a bytes holding it, or 0
;;
;; A directory entry's name, of the kind the ARGUMENT was.  CPython gives a
;; bytes path bytes names and a str path str names, and posix_path_arg used to
;; discard which it had been handed, so every caller built str.
;;
;; Shared with posixdir.asm, which needs the same decision three times.
;; ============================================================================
PNO_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
global posix_name_object
DEF_FUNC posix_name_object, PNO_FRAME
    test esi, esi
    jnz .pno_bytes
    call str_from_cstr_heap
    leave
    ret
.pno_bytes:
    push rdi
    push rdi                    ; twice: rsp stays 16-byte aligned
    call ap_strlen
    pop rdi
    pop rdi
    mov rsi, rax
    call bytes_from_data
    leave
    ret
END_FUNC posix_name_object

;; ============================================================================
;; posix_sized_object(rdi = data, rsi = length, rdx = 1 for bytes)
;;   -> (rax, edx) = a str or a bytes holding it
;;
;; The same decision for a run of bytes that is NOT NUL-terminated, which is
;; what readlink(2) writes.
;; ============================================================================
PSO_FRAME equ 16            ; + 0 pushes = 16, 16-aligned
global posix_sized_object
DEF_FUNC posix_sized_object, PSO_FRAME
    test rdx, rdx
    jnz .pso_bytes
    call str_new_heap
    leave
    ret
.pso_bytes:
    call bytes_from_data
    mov edx, TAG_PTR            ; bytes_from_data answers a bare pointer
    leave
    ret
END_FUNC posix_sized_object

;; ============================================================================
;; posix_stat_result(rdi = struct stat *) -> rax = a stat_result, or 0
;;
;; The ten sequence fields in CPython's order, then the six named-only ones.
;; st_mode, st_uid and st_gid are 32-bit fields: read as 64 bits each would
;; OR in its neighbour.
;;
;; The times come in three forms, as CPython's do: st_atime and friends are
;; FLOATS carrying the fractional seconds, the _ns fields carry the exact
;; whole nanoseconds, and the sequence entries 7..9 are the whole seconds as
;; ints.  os.path.getmtime hands its answer straight to arithmetic that
;; expects a float, and shutil.copystat and tarfile compare mtimes to
;; sub-second precision.
;; ============================================================================
PSR_BUF   equ 8
PSR_OBJ   equ 16
PSR_FRAME equ 32            ; + 1 push = 40... see below

; A whole-nanosecond timestamp: seconds * 1e9 + the nanosecond remainder.
; The three _ns fields published tv_nsec alone, so st_mtime_ns was a number
; below 1e9 -- bugs.md said they carried the exact value, and they did not.
%macro STAT_FIELD_NS 3          ; %1 = field index, %2 = tv_sec, %3 = tv_nsec
    mov rax, %2
    mov ecx, 1000000000
    imul rax, rcx
    add rax, %3
    mov rdi, rax
    call int_from_i64
    V_PACK rax, rdx
    mov rdx, rax
    mov rdi, [rbp - PSR_OBJ]
    mov esi, %1
    call structseq_set          ; takes over the reference
%endmacro

; A timestamp as a float: seconds + nanoseconds/1e9, which is what CPython
; publishes for st_atime, st_mtime and st_ctime.  They were whole-second ints
; here, so anything comparing two mtimes within the same second saw them as
; equal.
%macro STAT_FIELD_F 3           ; %1 = field index, %2 = tv_sec, %3 = tv_nsec
    cvtsi2sd xmm0, qword %2
    cvtsi2sd xmm1, qword %3
    divsd xmm1, [rel psr_1e9]
    addsd xmm0, xmm1
    call float_from_f64
    V_PACK rax, rdx
    mov rdx, rax
    mov rdi, [rbp - PSR_OBJ]
    mov esi, %1
    call structseq_set          ; takes over the reference
%endmacro

%macro STAT_FIELD_I 2           ; %1 = field index, %2 = the i64 to store
    mov rdi, %2
    call int_from_i64
    V_PACK rax, rdx
    mov rdx, rax
    mov rdi, [rbp - PSR_OBJ]
    mov esi, %1
    call structseq_set          ; takes over the reference
%endmacro

DEF_FUNC posix_stat_result, 40
    push rbx
    mov [rbp - PSR_BUF], rdi

    lea rdi, [rel stat_result_type]
    call structseq_new
    test rax, rax
    jz .psr_out
    mov [rbp - PSR_OBJ], rax
    mov rbx, [rbp - PSR_BUF]

    mov eax, [rbx + StatBuf.st_mode]        ; 32-bit, zero-extended
    STAT_FIELD_I 0, rax
    mov rbx, [rbp - PSR_BUF]
    STAT_FIELD_I 1, [rbx + StatBuf.st_ino]
    mov rbx, [rbp - PSR_BUF]
    STAT_FIELD_I 2, [rbx + StatBuf.st_dev]
    mov rbx, [rbp - PSR_BUF]
    STAT_FIELD_I 3, [rbx + StatBuf.st_nlink]
    mov rbx, [rbp - PSR_BUF]
    mov eax, [rbx + StatBuf.st_uid]
    STAT_FIELD_I 4, rax
    mov rbx, [rbp - PSR_BUF]
    mov eax, [rbx + StatBuf.st_gid]
    STAT_FIELD_I 5, rax
    mov rbx, [rbp - PSR_BUF]
    STAT_FIELD_I 6, [rbx + StatBuf.st_size]
    ; The sequence keeps the whole seconds; the names point at the floats
    ; below.  CPython does the same, and os.stat(p)[8] is an int there too.
    mov rbx, [rbp - PSR_BUF]
    STAT_FIELD_I 7, [rbx + StatBuf.st_atime]
    mov rbx, [rbp - PSR_BUF]
    STAT_FIELD_I 8, [rbx + StatBuf.st_mtime]
    mov rbx, [rbp - PSR_BUF]
    STAT_FIELD_I 9, [rbx + StatBuf.st_ctime]

    ; The named-only tail.
    mov rbx, [rbp - PSR_BUF]
    STAT_FIELD_NS 10, [rbx + StatBuf.st_atime], [rbx + StatBuf.st_atime_ns]
    mov rbx, [rbp - PSR_BUF]
    STAT_FIELD_NS 11, [rbx + StatBuf.st_mtime], [rbx + StatBuf.st_mtime_ns]
    mov rbx, [rbp - PSR_BUF]
    STAT_FIELD_NS 12, [rbx + StatBuf.st_ctime], [rbx + StatBuf.st_ctime_ns]
    mov rbx, [rbp - PSR_BUF]
    STAT_FIELD_I 13, [rbx + StatBuf.st_blksize]
    mov rbx, [rbp - PSR_BUF]
    STAT_FIELD_I 14, [rbx + StatBuf.st_blocks]
    mov rbx, [rbp - PSR_BUF]
    STAT_FIELD_I 15, [rbx + StatBuf.st_rdev]

    ; The float timestamps, which st_atime, st_mtime and st_ctime name.
    mov rbx, [rbp - PSR_BUF]
    STAT_FIELD_F 16, [rbx + StatBuf.st_atime], [rbx + StatBuf.st_atime_ns]
    mov rbx, [rbp - PSR_BUF]
    STAT_FIELD_F 17, [rbx + StatBuf.st_mtime], [rbx + StatBuf.st_mtime_ns]
    mov rbx, [rbp - PSR_BUF]
    STAT_FIELD_F 18, [rbx + StatBuf.st_ctime], [rbx + StatBuf.st_ctime_ns]

    mov rax, [rbp - PSR_OBJ]
.psr_out:
    pop rbx
    leave
    ret
END_FUNC posix_stat_result

;; ============================================================================
;; posix.stat(path) / posix.lstat(path) / posix.fstat(fd)
;; ============================================================================
PST_PATH  equ 8
PST_OWNED equ 16                     ; what posix_path_arg asked us to release
PST_NPOS  equ 24                     ; positional count, past the keywords
PST_BUF   equ 32 + StatBuf_size
PST_FRAME equ 32 + StatBuf_size      ; derived, not hand-picked: a struct in a
                                     ; frame outgrows a guessed offset silently

DEF_FUNC posix_stat, PST_FRAME
    test rsi, rsi
    jz .pst_argerr
    ; follow_symlinks=False makes this lstat.  The keyword was accepted and
    ; dropped -- nothing here read kw_names_pending -- so os.stat followed the
    ; link either way, and os.path.islink() could not tell.
    mov rax, [gs:ThreadState.kw_names_pending]
    test rax, rax
    jz .pst_no_kw
    mov qword [gs:ThreadState.kw_names_pending], 0
    mov rcx, [rax + PyTupleObject.ob_size]
    mov rdx, rsi
    sub rdx, rcx
    mov [rbp - PST_NPOS], rdx   ; the frame, not rdx: ap_strcmp clobbers it
    mov r9, [rax + PyTupleObject.ob_item]
    xor r8d, r8d
.pst_kw_loop:
    cmp r8, rcx
    jge .pst_no_kw
    push rcx
    push r8
    push r9
    push rdi
    mov r10, [r9 + r8*8]
    lea rdi, [r10 + PyStrObject.data]
    CSTRING rsi, "follow_symlinks"
    call ap_strcmp
    mov r11d, eax
    pop rdi
    pop r9
    pop r8
    pop rcx
    test r11d, r11d
    jnz .pst_kw_next
    push rcx
    push r8
    push r9
    push rdi
    mov r10, [rbp - PST_NPOS]
    add r10, r8
    mov rdi, [rdi + r10*8]
    call obj_is_true
    mov r11d, eax
    pop rdi
    pop r9
    pop r8
    pop rcx
    test r11d, r11d
    jnz .pst_kw_next
    ; A real tail call: posix_lstat builds its own frame, so this one has to
    ; be gone before the jump or its rsp is never restored.
    mov esi, 1                      ; nargs for lstat, which takes no keywords
    leave
    jmp posix_lstat
.pst_kw_next:
    inc r8
    jmp .pst_kw_loop
.pst_no_kw:
    mov rdi, [rdi]
    mov [rbp - PST_PATH], rdi
    ; os.stat(fd) is os.fstat(fd): CPython's stat takes an open file
    ; descriptor wherever it takes a path, and os.path.exists relies on it.
    ; int_is_integer wants the (payload, tag) pair, and it is the only test
    ; that says yes to a heap int and a bool as well as to an immediate.
    mov edx, TAG_PTR
    V_TEST_PTR rdi, rax
    jbe .pst_have_tag
    mov edx, TAG_SMALLINT
    V_IS_INT rdi, rax
    jae .pst_have_tag
    mov edx, TAG_FLOAT
.pst_have_tag:
    call int_is_integer
    test eax, eax
    jnz .pst_fd
    mov rdi, [rbp - PST_PATH]
    CSTRING rsi, "stat: path"
    mov edx, POSIX_PATH_KIND_FD
    call posix_path_arg
    test rax, rax
    jz .pst_fail
    mov [rbp - PST_OWNED], rdx
    lea rsi, [rbp - PST_BUF]
    mov rdi, rax
    call sys_stat
    POSIX_PATH_CHECK rax, [rbp - PST_PATH], [rbp - PST_OWNED]
    lea rdi, [rbp - PST_BUF]
    call posix_stat_result
    leave
    ret
.pst_fd:
    mov rdi, [rbp - PST_PATH]
    call posix_int_arg
    lea rsi, [rbp - PST_BUF]
    mov rdi, rax
    call sys_fstat
    POSIX_CHECK rax, 0
    lea rdi, [rbp - PST_BUF]
    call posix_stat_result
    leave
    ret
.pst_fail:
    xor eax, eax
    leave
    ret
.pst_argerr:
    RAISE exc_TypeError_type, "stat() takes at least 1 argument"
END_FUNC posix_stat

DEF_FUNC posix_lstat, PST_FRAME
    test rsi, rsi
    jz .plst_argerr
    mov rdi, [rdi]
    mov [rbp - PST_PATH], rdi
    CSTRING rsi, "lstat: path"
    mov edx, POSIX_PATH_KIND_PLAIN
    call posix_path_arg
    test rax, rax
    jz .plst_fail
    mov [rbp - PST_OWNED], rdx
    lea rsi, [rbp - PST_BUF]
    mov rdi, rax
    call sys_lstat
    POSIX_PATH_CHECK rax, [rbp - PST_PATH], [rbp - PST_OWNED]
    lea rdi, [rbp - PST_BUF]
    call posix_stat_result
    leave
    ret
.plst_fail:
    xor eax, eax
    leave
    ret
.plst_argerr:
    RAISE exc_TypeError_type, "lstat() takes at least 1 argument"
END_FUNC posix_lstat

DEF_FUNC posix_fstat, PST_FRAME
    test rsi, rsi
    jz .pfst_argerr
    mov rdi, [rdi]
    call posix_int_arg
    lea rsi, [rbp - PST_BUF]
    mov rdi, rax
    call sys_fstat
    POSIX_CHECK rax, 0
    lea rdi, [rbp - PST_BUF]
    call posix_stat_result
    leave
    ret
.pfst_argerr:
    RAISE exc_TypeError_type, "fstat() takes exactly 1 argument"
END_FUNC posix_fstat

;; ============================================================================
;; posix.listdir(path='.') -> list[str]
;;
;; getdents64 over a buffer of linux_dirent64 records, refilled until it
;; returns 0.  d_reclen is the stride and it is a TWO-byte field: a 64-bit
;; read ORs in d_type and five bytes of the name, and the resulting stride
;; walks off the end.  `movzx eax, word` is the whole of the fix.
;;
;; "." and ".." are filtered, as every listdir does.
;; ============================================================================
PLD_BUFSZ equ 32768

PLD_PATH  equ 8
PLD_FD    equ 16
PLD_LIST  equ 24
PLD_BUF   equ 32
PLD_N     equ 40            ; bytes getdents64 wrote this round
PLD_OFF   equ 48            ; the cursor into the buffer
PLD_OWNED equ 56            ; what posix_path_arg asked us to release
PLD_ISBYTES equ 72          ; the argument's kind, so the names are built of it
PLD_ERR   equ 64            ; the errno of a failed getdents64, held across
                            ; the cleanup that has to happen before it raises
PLD_FRAME equ 80            ; + 2 pushes = 96, 16-byte aligned

DEF_FUNC posix_listdir, PLD_FRAME
    push rbx
    push r12
    mov qword [rbp - PLD_BUF], 0
    mov qword [rbp - PLD_LIST], 0
    mov qword [rbp - PLD_FD], -1
    mov qword [rbp - PLD_OWNED], 0

    ; The default is ".", as os.listdir()'s is.
    test rsi, rsi
    jz .pld_dot
    mov rdi, [rdi]
    IS_NONE rdi, rax
    je .pld_dot
    mov [rbp - PLD_PATH], rdi
    CSTRING rsi, "listdir: path"
    mov edx, POSIX_PATH_KIND_FD_NONE
    call posix_path_arg
    test rax, rax
    jz .pld_fail
    mov rbx, rax
    mov [rbp - PLD_OWNED], rdx
    mov [rbp - PLD_ISBYTES], rcx    ; a bytes path gets bytes names
    jmp .pld_open
.pld_dot:
    mov qword [rbp - PLD_PATH], 0
    mov qword [rbp - PLD_ISBYTES], 0
    CSTRING rbx, "."

.pld_open:
    mov rdi, rbx
    mov esi, O_RDONLY | O_DIRECTORY | O_CLOEXEC
    xor edx, edx
    call sys_open
    POSIX_PATH_CHECK rax, [rbp - PLD_PATH], [rbp - PLD_OWNED]
    mov [rbp - PLD_FD], rax

    mov edi, PLD_BUFSZ
    call ap_malloc
    test rax, rax
    jz .pld_fail
    mov [rbp - PLD_BUF], rax

    xor edi, edi                    ; the default capacity
    call list_new
    test rax, rax
    jz .pld_fail
    mov [rbp - PLD_LIST], rax

.pld_refill:
    mov rdi, [rbp - PLD_FD]
    mov rsi, [rbp - PLD_BUF]
    mov edx, PLD_BUFSZ
    call sys_getdents64
    ; Not POSIX_CHECK: by here the descriptor is open, the 32 KiB buffer is
    ; allocated and the list is half built, and a raise abandons the C stack
    ; without running any of the cleanup below.  Close and free FIRST, then
    ; raise with the errno kept aside.
    cmp rax, -4095
    jb .pld_read_ok
    neg rax
    mov [rbp - PLD_ERR], rax
    mov rdi, [rbp - PLD_FD]
    call sys_close
    mov qword [rbp - PLD_FD], -1
    mov rdi, [rbp - PLD_BUF]
    call ap_free
    mov qword [rbp - PLD_BUF], 0
    mov rdi, [rbp - PLD_LIST]
    test rdi, rdi
    jz .pld_read_raise
    mov qword [rbp - PLD_LIST], 0
    call obj_decref
.pld_read_raise:
    mov rdi, [rbp - PLD_ERR]
    mov rsi, [rbp - PLD_PATH]
    call raise_oserror              ; does not return
.pld_read_ok:
    test rax, rax
    jz .pld_done                    ; 0 = the directory is exhausted
    mov [rbp - PLD_N], rax
    mov qword [rbp - PLD_OFF], 0

.pld_record:
    mov rax, [rbp - PLD_OFF]
    cmp rax, [rbp - PLD_N]
    jge .pld_refill
    mov rbx, [rbp - PLD_BUF]
    add rbx, rax                    ; rbx = this record
    ; The stride, read as the 16-bit field it is.
    movzx r12d, word [rbx + LinuxDirent64.d_reclen]

    lea rdi, [rbx + LinuxDirent64.d_name]
    ; Skip "." and ".."
    cmp byte [rdi], '.'
    jne .pld_keep
    cmp byte [rdi + 1], 0
    je .pld_next
    cmp byte [rdi + 1], '.'
    jne .pld_keep
    cmp byte [rdi + 2], 0
    je .pld_next

.pld_keep:
    ; Of the argument's own kind: os.listdir(b'.') is a list of bytes in
    ; CPython and was a list of str here -- the same defect as scandir's,
    ; in the same function, and not recorded beside it.
    mov esi, [rbp - PLD_ISBYTES]
    call posix_name_object
    test rax, rax
    jz .pld_fail
    mov rbx, rax
    mov rdi, [rbp - PLD_LIST]
    mov rsi, rbx
    call list_append
    mov rdi, rbx
    call obj_decref                 ; list_append took its own

.pld_next:
    mov rax, [rbp - PLD_OFF]
    add rax, r12
    mov [rbp - PLD_OFF], rax
    jmp .pld_record

.pld_done:
    mov rdi, [rbp - PLD_FD]
    call sys_close
    mov rdi, [rbp - PLD_BUF]
    call ap_free
    mov rax, [rbp - PLD_LIST]
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

.pld_fail:
    POSIX_PATH_DONE [rbp - PLD_OWNED]
    mov rdi, [rbp - PLD_FD]
    test rdi, rdi
    jl .pld_fail_buf
    call sys_close
.pld_fail_buf:
    mov rdi, [rbp - PLD_BUF]
    test rdi, rdi
    jz .pld_fail_list
    call ap_free
.pld_fail_list:
    mov rdi, [rbp - PLD_LIST]
    test rdi, rdi
    jz .pld_fail_out
    call obj_decref
.pld_fail_out:
    xor eax, eax
    xor edx, edx
    pop r12
    pop rbx
    leave
    ret
END_FUNC posix_listdir

;; ============================================================================
;; posix.getcwd() -> str   /   posix.getcwdb() -> bytes
;;
;; The buffer doubles until getcwd stops answering -ERANGE, so a deep path is
;; not a truncation.
;; ============================================================================
PCW_BUF   equ 8
PCW_SIZE  equ 16
PCW_FRAME equ 32            ; + 1 push = 40, padded to keep rsp aligned

DEF_FUNC posix_getcwd_impl, 40
    push rbx
    mov ebx, edi                ; 0 = str, 1 = bytes
    mov qword [rbp - PCW_SIZE], 512
.pcw_try:
    mov rdi, [rbp - PCW_SIZE]
    call ap_malloc
    test rax, rax
    jz .pcw_oom
    mov [rbp - PCW_BUF], rax
    mov rdi, rax
    mov rsi, [rbp - PCW_SIZE]
    call sys_getcwd
    cmp rax, -34                ; -ERANGE: the buffer was too small
    jne .pcw_have
    mov rdi, [rbp - PCW_BUF]
    call ap_free
    shl qword [rbp - PCW_SIZE], 1
    cmp qword [rbp - PCW_SIZE], 1 << 20
    jb .pcw_try
    mov edi, 36                 ; ENAMETOOLONG
    xor esi, esi
    call raise_oserror

.pcw_have:
    ; The buffer is ours and raise_oserror does not come back, so a failure
    ; that is not ERANGE -- the working directory unlinked, say -- leaked it
    ; on every call.  Release it before letting POSIX_CHECK raise.
    cmp rax, -4095
    jb .pcw_ok
    push rax
    sub rsp, 8
    mov rdi, [rbp - PCW_BUF]
    call ap_free
    add rsp, 8
    pop rax
    POSIX_CHECK rax, 0
.pcw_ok:
    ; getcwd returns the length INCLUDING the NUL.
    dec rax
    mov rdi, [rbp - PCW_BUF]
    mov rsi, rax
    test ebx, ebx
    jnz .pcw_bytes
    call str_new_heap
    jmp .pcw_wrap
.pcw_bytes:
    call bytes_from_data
    mov edx, TAG_PTR
.pcw_wrap:
    push rax
    push rdx
    mov rdi, [rbp - PCW_BUF]
    call ap_free
    pop rdx
    pop rax
    pop rbx
    leave
    ret

.pcw_oom:
    RAISE exc_OSError_type, "cannot allocate a path buffer"
END_FUNC posix_getcwd_impl

DEF_FUNC_BARE posix_getcwd
    xor edi, edi
    jmp posix_getcwd_impl
END_FUNC posix_getcwd

DEF_FUNC_BARE posix_getcwdb
    mov edi, 1
    jmp posix_getcwd_impl
END_FUNC posix_getcwdb

;; ============================================================================
;; The one-path calls: unlink, rmdir, and the two-path rename.
;;
;; Each returns None, and each names the offending path in its OSError -- which
;; is the whole reason posix_path_arg hands the Value back rather than only
;; the pointer.
;; ============================================================================
P1_PATH   equ 8
P1_PTR    equ 16
P1_OWNED  equ 24            ; what posix_path_arg asked us to release
P1_MODE   equ 32            ; the mode, converted before the path is resolved
P1_FRAME  equ 48            ; + 0 pushes = 48

;; ============================================================================
;; posix_raise_missing(rdi = the function's name, rsi = the parameter's name,
;;                     rdx = its 1-based position) -- does not return
;;
;; CPython's argument clinic: "chdir() missing required argument 'path'
;; (pos 1)".  Every one of these said "takes exactly N arguments", which does
;; not say WHICH one is missing -- the only thing the caller needs.
;; ============================================================================
PRM_FUNC  equ 8
PRM_ARG   equ 16
PRM_POS   equ 24
PRM_BUF   equ 208
PRM_FRAME equ 208           ; + 0 pushes = 208, 16-aligned
global posix_raise_missing
DEF_FUNC posix_raise_missing, PRM_FRAME
    mov [rbp - PRM_FUNC], rdi
    mov [rbp - PRM_ARG], rsi
    mov [rbp - PRM_POS], rdx
    lea rdi, [rbp - PRM_BUF]
    mov rsi, [rbp - PRM_FUNC]
    extern rbt_append_cstr
    call rbt_append_cstr
    mov rdi, rax
    CSTRING rsi, "() missing required argument '"
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - PRM_ARG]
    call rbt_append_cstr
    mov rdi, rax
    CSTRING rsi, "' (pos "
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - PRM_POS]
    extern msg_append_i64
    call msg_append_i64
    mov rdi, rax
    CSTRING rsi, ")"
    call rbt_append_cstr
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rbp - PRM_BUF]
    call raise_exception
END_FUNC posix_raise_missing

;; PM_MISSING func, arg, pos -- the three-argument form, spelled once.
%macro PM_MISSING 3
    CSTRING rdi, %1
    CSTRING rsi, %2
    mov edx, %3
    call posix_raise_missing
%endmacro

%macro POSIX_ONE_PATH 4         ; %1 = name, %2 = the syscall,
                                ; %3 = the function's name for the arity
                                ; message, %4 = the "<func>: path" prefix
DEF_FUNC %1, P1_FRAME
    test rsi, rsi
    jz %%argerr
    mov rdi, [rdi]
    mov [rbp - P1_PATH], rdi
    CSTRING rsi, %4
    mov edx, POSIX_PATH_KIND_PLAIN
    call posix_path_arg
    test rax, rax
    jz %%fail
    mov [rbp - P1_OWNED], rdx
    mov rdi, rax
    call %2
    POSIX_PATH_CHECK rax, [rbp - P1_PATH], [rbp - P1_OWNED]
    LOAD_NONE rax
    mov edx, TAG_PTR
    leave
    ret
%%fail:
    xor eax, eax
    xor edx, edx
    leave
    ret
%%argerr:
    PM_MISSING %3, "path", 1
END_FUNC %1
%endmacro

POSIX_ONE_PATH posix_unlink, sys_unlink, "unlink", "unlink: path"
POSIX_ONE_PATH posix_rmdir,  sys_rmdir,  "rmdir",  "rmdir: path"
POSIX_ONE_PATH posix_chdir,  sys_chdir,  "chdir",  "chdir: path"

;; posix.mkdir(path, mode=0o777)
DEF_FUNC posix_mkdir, P1_FRAME
    test rsi, rsi
    jz .pmk_argerr
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    ; The mode is converted FIRST: posix_int_arg raises for a bad one, and a
    ; raise abandons the C stack, so resolving the path before it would
    ; strand the string __fspath__ built.
    mov esi, 0o777
    cmp r12, 2
    jl .pmk_have_mode
    mov rdi, [rbx + 8]
    call posix_int_arg
    mov rsi, rax
.pmk_have_mode:
    mov [rbp - P1_MODE], rsi
    mov rdi, [rbx]
    mov [rbp - P1_PATH], rdi
    CSTRING rsi, "mkdir: path"
    mov edx, POSIX_PATH_KIND_PLAIN
    call posix_path_arg
    test rax, rax
    jz .pmk_fail
    mov [rbp - P1_PTR], rax
    mov [rbp - P1_OWNED], rdx
    mov rsi, [rbp - P1_MODE]
.pmk_go:
    mov rdi, [rbp - P1_PTR]
    call sys_mkdir
    POSIX_PATH_CHECK rax, [rbp - P1_PATH], [rbp - P1_OWNED]
    LOAD_NONE rax
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret
.pmk_fail:
    xor eax, eax
    xor edx, edx
    pop r12
    pop rbx
    leave
    ret
.pmk_argerr:
    RAISE exc_TypeError_type, "mkdir() takes at least 1 argument"
END_FUNC posix_mkdir

;; posix.chmod(path, mode)
DEF_FUNC posix_chmod, P1_FRAME
    cmp rsi, 2
    jl .pch_argerr
    push rbx
    push r12
    mov rbx, rdi
    mov rdi, [rbx + 8]
    call posix_int_arg          ; the mode first: see mkdir
    mov [rbp - P1_MODE], rax
    mov rdi, [rbx]
    mov [rbp - P1_PATH], rdi
    CSTRING rsi, "chmod: path"
    mov edx, POSIX_PATH_KIND_PLAIN
    call posix_path_arg
    test rax, rax
    jz .pch_fail
    mov r12, rax
    mov [rbp - P1_OWNED], rdx
    mov rsi, [rbp - P1_MODE]
    mov rdi, r12
    call sys_chmod
    POSIX_PATH_CHECK rax, [rbp - P1_PATH], [rbp - P1_OWNED]
    LOAD_NONE rax
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret
.pch_fail:
    xor eax, eax
    xor edx, edx
    pop r12
    pop rbx
    leave
    ret
.pch_argerr:
    RAISE exc_TypeError_type, "chmod() takes at least 2 arguments"
END_FUNC posix_chmod

;; posix.rename(src, dst) / posix.replace(src, dst)
;;
;; rename(2) already replaces the destination, so os.replace and os.rename are
;; the same call here -- which is what they are on POSIX in CPython too.  The
;; two paths must BOTH be resolved before either syscall argument is used:
;; posix_path_arg can run __fspath__, which is arbitrary Python.
PRN_SRC   equ 8
PRN_DST   equ 16
PRN_SPTR  equ 24
PRN_SOWN  equ 32            ; what each posix_path_arg asked us to release
PRN_DOWN  equ 40
PRN_FRAME equ 56            ; + 1 push = 64, 16-aligned

DEF_FUNC posix_rename, PRN_FRAME
    push rbx
    cmp rsi, 2
    jl .prn_argerr
    mov rbx, rdi
    mov rdi, [rbx]
    mov [rbp - PRN_SRC], rdi
    mov qword [rbp - PRN_SOWN], 0
    mov qword [rbp - PRN_DOWN], 0
    CSTRING rsi, "rename: src"
    mov edx, POSIX_PATH_KIND_PLAIN
    call posix_path_arg
    test rax, rax
    jz .prn_fail
    mov [rbp - PRN_SPTR], rax
    mov [rbp - PRN_SOWN], rdx
    mov rdi, [rbx + 8]
    mov [rbp - PRN_DST], rdi
    CSTRING rsi, "rename: dst"
    mov edx, POSIX_PATH_KIND_PLAIN
    call posix_path_arg
    test rax, rax
    jz .prn_fail
    mov [rbp - PRN_DOWN], rdx
    mov rsi, rax
    mov rdi, [rbp - PRN_SPTR]
    call sys_rename
    ; Both paths stay alive across the check: CPython reports
    ; "... : 'src' -> 'dst'", and this named only the source because the
    ; destination was released first.
    cmp rax, -4095
    jb .prn_ok
    mov rdi, rax
    neg rdi
    mov rsi, [rbp - PRN_SRC]
    mov rdx, [rbp - PRN_SOWN]
    mov rcx, [rbp - PRN_DST]
    mov r8, [rbp - PRN_DOWN]
    extern raise_oserror_owned2
    call raise_oserror_owned2   ; does not return
.prn_ok:
    POSIX_PATH_DONE [rbp - PRN_DOWN]
    POSIX_PATH_DONE [rbp - PRN_SOWN]
    LOAD_NONE rax
    mov edx, TAG_PTR
    pop rbx
    leave
    ret
.prn_fail:
    ; The second path may have failed after the first was resolved.
    POSIX_PATH_DONE [rbp - PRN_DOWN]
    POSIX_PATH_DONE [rbp - PRN_SOWN]
    xor eax, eax
    xor edx, edx
    pop rbx
    leave
    ret
.prn_argerr:
    RAISE exc_TypeError_type, "rename() takes exactly 2 arguments"
END_FUNC posix_rename

;; posix.symlink(src, dst) -- create dst as a symbolic link to src
;;
;; readlink, lstat and stat's follow_symlinks=False were all here, so a link
;; could be inspected and read but never made -- which is why the regression
;; test for follow_symlinks had to make do with a regular file.
;;
;; Both paths are resolved before either is used, for the reason rename's
;; are: posix_path_arg can run __fspath__, which is arbitrary Python.
;; symlink(2) takes (target, linkpath), which is the same order as the
;; Python signature.
PSL_SRC   equ 8
PSL_DST   equ 16
PSL_SPTR  equ 24
PSL_SOWN  equ 32
PSL_DOWN  equ 40
PSL_FRAME equ 56            ; + 1 push = 64, 16-aligned

DEF_FUNC posix_symlink, PSL_FRAME
    push rbx
    cmp rsi, 2
    jl .psl_argerr
    mov rbx, rdi
    mov rdi, [rbx]
    mov [rbp - PSL_SRC], rdi
    mov qword [rbp - PSL_SOWN], 0
    mov qword [rbp - PSL_DOWN], 0
    CSTRING rsi, "symlink: src"
    mov edx, POSIX_PATH_KIND_PLAIN
    call posix_path_arg
    test rax, rax
    jz .psl_fail
    mov [rbp - PSL_SPTR], rax
    mov [rbp - PSL_SOWN], rdx
    mov rdi, [rbx + 8]
    mov [rbp - PSL_DST], rdi
    CSTRING rsi, "symlink: dst"
    mov edx, POSIX_PATH_KIND_PLAIN
    call posix_path_arg
    test rax, rax
    jz .psl_fail
    mov [rbp - PSL_DOWN], rdx
    mov rsi, rax
    mov rdi, [rbp - PSL_SPTR]
    extern sys_symlink
    call sys_symlink
    ; The error names the LINK, which is the path that could not be created;
    ; CPython's symlink reports both, target first.
    cmp rax, -4095
    jb .psl_ok
    mov rdi, rax
    neg rdi
    mov rsi, [rbp - PSL_SRC]
    mov rdx, [rbp - PSL_SOWN]
    mov rcx, [rbp - PSL_DST]
    mov r8, [rbp - PSL_DOWN]
    call raise_oserror_owned2   ; does not return
.psl_ok:
    POSIX_PATH_DONE [rbp - PSL_DOWN]
    POSIX_PATH_DONE [rbp - PSL_SOWN]
    LOAD_NONE rax
    mov edx, TAG_PTR
    pop rbx
    leave
    ret
.psl_fail:
    POSIX_PATH_DONE [rbp - PSL_DOWN]
    POSIX_PATH_DONE [rbp - PSL_SOWN]
    xor eax, eax
    xor edx, edx
    pop rbx
    leave
    ret
.psl_argerr:
    RAISE exc_TypeError_type, "symlink() takes at least 2 arguments"
END_FUNC posix_symlink

;; posix.readlink(path) -> str
PRL_PATH  equ 8
PRL_BUF   equ 16
PRL_SIZE  equ 24
PRL_PTR   equ 32
PRL_OWNED equ 40            ; what posix_path_arg asked us to release
PRL_ISBYTES equ 48          ; the argument's kind: the answer is built of it
PRL_FRAME equ 64            ; + 0 pushes = 64, 16-aligned

DEF_FUNC posix_readlink, PRL_FRAME
    test rsi, rsi
    jz .prl_argerr
    mov rdi, [rdi]
    mov qword [rbp - PRL_OWNED], 0
    mov [rbp - PRL_PATH], rdi
    CSTRING rsi, "readlink: path"
    mov edx, POSIX_PATH_KIND_PLAIN
    call posix_path_arg
    test rax, rax
    jz .prl_fail
    mov [rbp - PRL_PTR], rax
    mov [rbp - PRL_OWNED], rdx
    mov [rbp - PRL_ISBYTES], rcx
    mov qword [rbp - PRL_SIZE], 512
.prl_try:
    mov rdi, [rbp - PRL_SIZE]
    call ap_malloc
    test rax, rax
    jz .prl_fail
    mov [rbp - PRL_BUF], rax
    mov rdi, [rbp - PRL_PTR]
    mov rsi, rax
    mov rdx, [rbp - PRL_SIZE]
    call sys_readlink
    ; readlink truncates silently rather than reporting ERANGE, so a result
    ; that exactly fills the buffer means "there may be more".
    cmp rax, -4095
    jae .prl_err
    cmp rax, [rbp - PRL_SIZE]
    jl .prl_have
    mov rdi, [rbp - PRL_BUF]
    push rax
    push rax
    call ap_free
    pop rax
    pop rax
    shl qword [rbp - PRL_SIZE], 1
    cmp qword [rbp - PRL_SIZE], 1 << 20
    jb .prl_try
    POSIX_PATH_DONE [rbp - PRL_OWNED]
    mov edi, 36                     ; ENAMETOOLONG
    mov rsi, [rbp - PRL_PATH]
    call raise_oserror
.prl_err:
    mov rdi, [rbp - PRL_BUF]
    push rax
    push rax
    call ap_free
    pop rax
    pop rax
    POSIX_PATH_CHECK rax, [rbp - PRL_PATH], [rbp - PRL_OWNED]
.prl_have:
    POSIX_PATH_DONE [rbp - PRL_OWNED]
    ; readlink(b'x') answers a bytes in CPython, as scandir and listdir do.
    ; The target is not NUL-terminated -- readlink does not terminate it -- so
    ; the length is carried rather than measured.
    mov rdi, [rbp - PRL_BUF]
    mov rsi, rax
    mov rdx, [rbp - PRL_ISBYTES]
    call posix_sized_object
    push rax
    push rdx
    mov rdi, [rbp - PRL_BUF]
    call ap_free
    pop rdx
    pop rax
    leave
    ret
.prl_fail:
    POSIX_PATH_DONE [rbp - PRL_OWNED]
    xor eax, eax
    xor edx, edx
    leave
    ret
.prl_argerr:
    RAISE exc_TypeError_type, "readlink() takes exactly 1 argument"
END_FUNC posix_readlink

;; ============================================================================
;; The file-descriptor calls: open, close, read, write, lseek, dup, access.
;; ============================================================================
POP_PATH  equ 8
POP_PTR   equ 16
POP_OWNED equ 24            ; what posix_path_arg asked us to release
POP_FLAGS equ 32            ; both converted before the path is resolved
POP_MODE  equ 40
POP_FRAME equ 48            ; + 2 pushes = 64

DEF_FUNC posix_open, POP_FRAME
    cmp rsi, 2
    jl .pop_argerr
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    ; The flags and the mode are converted FIRST: posix_int_arg raises for a
    ; bad one, and a raise abandons the C stack, so resolving the path before
    ; them would strand the string __fspath__ built.
    mov rdi, [rbx + 8]
    call posix_int_arg
    mov [rbp - POP_FLAGS], rax
    mov qword [rbp - POP_MODE], 0o777
    cmp r12, 3
    jl .pop_have_mode
    mov rdi, [rbx + 16]
    call posix_int_arg
    mov [rbp - POP_MODE], rax
.pop_have_mode:
    mov rdi, [rbx]
    mov [rbp - POP_PATH], rdi
    CSTRING rsi, "open: path"
    mov edx, POSIX_PATH_KIND_PLAIN
    call posix_path_arg
    test rax, rax
    jz .pop_fail
    mov [rbp - POP_PTR], rax
    mov [rbp - POP_OWNED], rdx
    mov rsi, [rbp - POP_FLAGS]
    mov rdx, [rbp - POP_MODE]
.pop_go:
    mov rdi, [rbp - POP_PTR]
    call sys_open
    POSIX_PATH_CHECK rax, [rbp - POP_PATH], [rbp - POP_OWNED]
    mov rdi, rax
    call int_from_i64
    V_PACK rax, rdx
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret
.pop_fail:
    xor eax, eax
    xor edx, edx
    pop r12
    pop rbx
    leave
    ret
.pop_argerr:
    RAISE exc_TypeError_type, "open() takes at least 2 arguments"
END_FUNC posix_open

;; ============================================================================
;; posix_int_arg(rdi = a Value) -> rax = the integer it holds, or raises
;;
;; val_to_i64 trusts its caller and falls into int_to_i64, which reads
;; PyIntObject.compact unconditionally.  Every descriptor, mode and flag here
;; went through it unchecked: posix.access(path, 0.5) dereferenced a double's
;; raw bits, and posix.close("x") read PyStrObject.ob_length as the number --
;; 1 for a one-character string -- and closed stdout, silently.
;; ============================================================================
DEF_FUNC posix_int_arg, 8            ; 1 pushes, so rsp is 16-aligned
    push rdi
    V_UNPACK rdi, rdx
    call int_is_integer
    test eax, eax
    jz .pia_bad
    ; The width check comes FIRST.  A descriptor of 2**64 + 3 truncated to 3
    ; and posix.close() closed someone else's file; obj_as_index refuses such
    ; a value itself now, but it words the refusal for an index -- and a
    ; descriptor is a C int, which is how CPython words this one.
    pop rdi
    push rdi
    V_UNPACK rdi, rdx
    push rdi
    push rdx
    call int_fits_i64
    pop rdx
    pop rdi
    test eax, eax
    jz .pia_range
    call obj_as_index
    pop rdi
    leave
    ret
.pia_range:
    pop rdi
    RAISE exc_OverflowError_type, "Python int too large to convert to C int"
.pia_bad:
    pop rdi
    lea rsi, [rel pm_int_required]
    mov rdx, rdi
    lea rdi, [rel exc_TypeError_type]
    call posix_raise_typename
    ud2
END_FUNC posix_int_arg

;; posix_raise_typename(rdi = type, rsi = prefix cstr, rdx = the object)
;; Builds "<prefix> <typename> ..." the way CPython words it.
DEF_FUNC posix_raise_typename
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rdx
    lea rdi, [rel pm_msgbuf]
    mov byte [rdi], 0x27        ; an apostrophe
    inc rdi
    mov rsi, r12
    V_TEST_PTR rsi, rax
    ja .prt_immediate
    test rsi, rsi
    jz .prt_int
    mov rsi, [rsi + PyObject.ob_type]
    mov rsi, [rsi + PyTypeObject.tp_name]
    jmp .prt_have
.prt_immediate:
    ; An immediate is an int or a float, and the message has to say which.
    V_IS_FLOAT rsi, rax         ; the macro leaves "float" as below-or-equal
    ja .prt_int
    lea rsi, [rel pm_name_float]
    jmp .prt_have
.prt_int:
    lea rsi, [rel pm_name_int]
.prt_have:
    mov edx, 40
    call posix_copy_bounded
    mov byte [rax], 0x27
    inc rax
    mov rdi, rax
    lea rsi, [rel pm_int_required]
    mov edx, 80
    call posix_copy_bounded
    mov rdi, rbx
    lea rsi, [rel pm_msgbuf]
    call raise_exception
    ud2
END_FUNC posix_raise_typename

;; posix_copy_bounded(rdi = dest, rsi = src cstr, rdx = max) -> rax = the NUL
;; posix_typename_of(rdi = dest, rsi = a Value) -> rax = the NUL after the name
global posix_typename_of
DEF_FUNC posix_typename_of
    V_TEST_PTR rsi, rax
    ja .pto_immediate
    test rsi, rsi
    jz .pto_int
    mov rsi, [rsi + PyObject.ob_type]
    mov rsi, [rsi + PyTypeObject.tp_name]
    jmp .pto_have
.pto_immediate:
    V_IS_FLOAT rsi, rax
    ja .pto_int
    lea rsi, [rel pm_name_float]
    jmp .pto_have
.pto_int:
    lea rsi, [rel pm_name_int]
.pto_have:
    mov edx, 40
    call posix_copy_bounded
    leave
    ret
END_FUNC posix_typename_of

global posix_copy_bounded
DEF_FUNC posix_copy_bounded
    xor ecx, ecx
.pcb_loop:
    cmp rcx, rdx
    jge .pcb_done
    mov al, [rsi + rcx]
    test al, al
    jz .pcb_done
    mov [rdi + rcx], al
    inc rcx
    jmp .pcb_loop
.pcb_done:
    lea rax, [rdi + rcx]
    mov byte [rax], 0
    leave
    ret
END_FUNC posix_copy_bounded

DEF_FUNC posix_close, 16
    test rsi, rsi
    jz .pcl_argerr
    mov rdi, [rdi]
    call posix_int_arg
    mov rdi, rax
    call sys_close
    POSIX_CHECK rax, 0
    LOAD_NONE rax
    mov edx, TAG_PTR
    leave
    ret
.pcl_argerr:
    RAISE exc_TypeError_type, "close() takes exactly 1 argument"
END_FUNC posix_close

;; posix.read(fd, n) -> bytes
PRD_BUF   equ 8
PRD_FRAME equ 16            ; + 2 pushes = 32

DEF_FUNC posix_read, PRD_FRAME
    cmp rsi, 2
    jl .prd_argerr
    push rbx
    push r12
    mov rbx, rdi
    mov rdi, [rbx]
    call posix_int_arg
    mov r12, rax                    ; fd
    mov rdi, [rbx + 8]
    call posix_int_arg
    mov rbx, rax                    ; n
    test rbx, rbx
    js .prd_negative
    mov rdi, rbx
    test rdi, rdi
    jnz .prd_alloc
    mov edi, 1                      ; read(fd, buf, 0) still wants a buffer
.prd_alloc:
    call ap_malloc
    test rax, rax
    jz .prd_fail
    mov [rbp - PRD_BUF], rax
    mov rdi, r12
    mov rsi, rax
    mov rdx, rbx
    ; io_read_retry, not sys_read: os.read blocks, and a Python signal
    ; handler has to run while it is blocked.  _pyio's FileIO is built on
    ; os.read, so CPython's test_io hangs on this one too.
    extern io_read_retry
    call io_read_retry
    cmp rax, -4
    je .prd_handler_raised
    cmp rax, -4095
    jb .prd_ok
    push rax
    push rax
    mov rdi, [rbp - PRD_BUF]
    call ap_free
    pop rax
    pop rax
    POSIX_CHECK rax, 0
.prd_handler_raised:
    ; A Python signal handler raised while the read was interrupted; its
    ; exception is the caller's, and the buffer is this frame's.
    mov rdi, [rbp - PRD_BUF]
    call ap_free
    extern eval_exception_unwind
    pop r12
    pop rbx
    leave
    jmp eval_exception_unwind

.prd_ok:
    mov rdi, [rbp - PRD_BUF]
    mov rsi, rax
    call bytes_from_data
    push rax
    push rax
    mov rdi, [rbp - PRD_BUF]
    call ap_free
    pop rax
    pop rax
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret
.prd_negative:
    RAISE exc_ValueError_type, "negative read count"
.prd_fail:
    xor eax, eax
    xor edx, edx
    pop r12
    pop rbx
    leave
    ret
.prd_argerr:
    RAISE exc_TypeError_type, "read() takes exactly 2 arguments"
END_FUNC posix_read

;; posix.write(fd, data) -> int
;;
;; 24, not 16: the `push rbx` below comes after a branch, so `push rbp` plus
;; the frame plus that push left rsp eight out for the whole body.  That was
;; harmless while the only call was a leaf syscall; io_write_retry reaches
;; signal_run_pending and from there arbitrary Python.
DEF_FUNC posix_write, 24
    ; The push comes BEFORE the arity branch: after it, lint's push counter --
    ; which stops at the first non-push instruction -- could not see it, and
    ; the frame that satisfies the real parity looked wrong to the gate.  The
    ; refusal below does not return, so it owes nothing back.
    push rbx
    cmp rsi, 2
    jl .pwr_argerr
    mov rbx, rdi
    mov rdi, [rbx]
    call posix_int_arg
    mov rdi, rax                    ; fd... but the buffer comes next
    push rdi
    push rdi
    ; Anything bytes-LIKE, which is what CPython's Py_buffer means here.  This
    ; took bytes and bytearray only, so a MEMORYVIEW was refused -- and
    ; subprocess's _communicate writes one: `os.write(key.fd, chunk)` where
    ; chunk is a slice of memoryview(input).  Every communicate() with input
    ; died there, and with the pipe still open the child never saw EOF and
    ; nobody ever exited.
    mov rdi, [rbx + 8]
    extern bytes_like_ptr_len
    call bytes_like_ptr_len         ; rax = data, r10 = length, ecx = ok
    test ecx, ecx
    jz .pwr_badbuf
    mov rsi, rax
    mov rdx, r10
    pop rdi
    pop rdi
    extern io_write_retry
    call io_write_retry
    cmp rax, -4
    je .pwr_handler_raised
    POSIX_CHECK rax, 0
    mov rdi, rax
    call int_from_i64
    V_PACK rax, rdx
    mov edx, TAG_PTR
    pop rbx
    leave
    ret
.pwr_handler_raised:
    ; A Python signal handler raised while the write was interrupted; its
    ; exception is the caller's.
    extern eval_exception_unwind
    pop rbx
    leave
    jmp eval_exception_unwind

.pwr_badbuf:
    pop rdi
    pop rdi
    RAISE exc_TypeError_type, "a bytes-like object is required"
.pwr_argerr:
    RAISE exc_TypeError_type, "write() takes exactly 2 arguments"
END_FUNC posix_write

;; posix.lseek(fd, pos, whence) -> int
DEF_FUNC posix_lseek, 16
    cmp rsi, 3
    jl .pls_argerr
    push rbx
    push r12
    mov rbx, rdi
    mov rdi, [rbx]
    call posix_int_arg
    mov r12, rax
    mov rdi, [rbx + 8]
    call posix_int_arg
    push rax
    push rax
    mov rdi, [rbx + 16]
    call posix_int_arg
    mov rdx, rax
    pop rsi
    pop rsi
    mov rdi, r12
    call sys_lseek
    POSIX_CHECK rax, 0
    mov rdi, rax
    call int_from_i64
    V_PACK rax, rdx
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret
.pls_argerr:
    RAISE exc_TypeError_type, "lseek() takes exactly 3 arguments"
END_FUNC posix_lseek

DEF_FUNC posix_dup, 16
    test rsi, rsi
    jz .pdp_argerr
    mov rdi, [rdi]
    call posix_int_arg
    mov rdi, rax
    call sys_dup
    POSIX_CHECK rax, 0
    mov rdi, rax
    call int_from_i64
    V_PACK rax, rdx
    mov edx, TAG_PTR
    leave
    ret
.pdp_argerr:
    RAISE exc_TypeError_type, "dup() takes exactly 1 argument"
END_FUNC posix_dup

;; posix.access(path, mode) -> bool -- and it answers False rather than
;; raising, which is the one call in the family that swallows its errno.
PAC_OWNED equ 8
PAC_MODE  equ 16
PAC_FRAME equ 32            ; + 2 pushes = 48

DEF_FUNC posix_access, PAC_FRAME
    cmp rsi, 2
    jl .pac_argerr
    push rbx
    push r12
    mov rbx, rdi
    mov qword [rbp - PAC_OWNED], 0
    mov rdi, [rbx + 8]
    call posix_int_arg          ; the mode first: see mkdir
    mov [rbp - PAC_MODE], rax
    mov rdi, [rbx]
    CSTRING rsi, "access: path"
    mov edx, POSIX_PATH_KIND_PLAIN
    call posix_path_arg
    test rax, rax
    jz .pac_fail
    mov r12, rax
    mov [rbp - PAC_OWNED], rdx
    mov rsi, [rbp - PAC_MODE]
    mov rdi, r12
    call sys_access
    POSIX_PATH_DONE [rbp - PAC_OWNED]
    test rax, rax
    jnz .pac_false
    lea rax, [rel bool_true]
    jmp .pac_out
.pac_false:
    lea rax, [rel bool_false]
.pac_out:
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret
.pac_fail:
    POSIX_PATH_DONE [rbp - PAC_OWNED]
    xor eax, eax
    xor edx, edx
    pop r12
    pop rbx
    leave
    ret
.pac_argerr:
    RAISE exc_TypeError_type, "access() takes exactly 2 arguments"
END_FUNC posix_access

;; posix.pipe() -> (r, w)
PPI_FDS   equ 8             ; two ints
PPI_TUP   equ 16
PPI_FRAME equ 32            ; + 0 pushes = 32

DEF_FUNC posix_pipe, PPI_FRAME
    lea rdi, [rbp - PPI_FDS]
    mov esi, O_CLOEXEC
    call sys_pipe2
    POSIX_CHECK rax, 0
    mov edi, 2
    call tuple_new
    test rax, rax
    jz .ppi_fail
    mov [rbp - PPI_TUP], rax
    mov edi, [rbp - PPI_FDS]
    movsxd rdi, edi
    call int_from_i64
    V_PACK rax, rdx
    mov rcx, [rbp - PPI_TUP]
    mov rcx, [rcx + PyTupleObject.ob_item]      ; reload: the call moved it
    mov [rcx], rax
    mov edi, [rbp - PPI_FDS + 4]
    movsxd rdi, edi
    call int_from_i64
    V_PACK rax, rdx
    mov rcx, [rbp - PPI_TUP]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov [rcx + 8], rax
    mov rax, [rbp - PPI_TUP]
    mov edx, TAG_PTR
    leave
    ret
.ppi_fail:
    xor eax, eax
    xor edx, edx
    leave
    ret
END_FUNC posix_pipe

;; posix.getpid() -> int
DEF_FUNC posix_getpid, 16
    call sys_getpid
    mov rdi, rax
    call int_from_i64
    V_PACK rax, rdx
    mov edx, TAG_PTR
    leave
    ret
END_FUNC posix_getpid

;; posix.umask(mask) -> int
DEF_FUNC posix_umask, 16
    test rsi, rsi
    jz .pum_argerr
    mov rdi, [rdi]
    call posix_int_arg
    mov rdi, rax
    call sys_umask
    POSIX_CHECK rax, 0
    mov rdi, rax
    call int_from_i64
    V_PACK rax, rdx
    mov edx, TAG_PTR
    leave
    ret
.pum_argerr:
    RAISE exc_TypeError_type, "umask() takes exactly 1 argument"
END_FUNC posix_umask

;; ============================================================================
;; posix.ioctl(fd, request, arg=0) -> bytes, or the call's own result
;;
;; The one syscall a terminal is configured through.  CPython puts it in
;; fcntl and termios is written against it in C; here termios is Python, the
;; way _socket and select are, so the raw call is what has to exist.
;;
;; A bytes-like arg is copied into a writable buffer, handed to the kernel
;; and given back -- which is how TCGETS answers, since ioctl writes through
;; the pointer.  An integer arg is passed by value and the call's own return
;; value comes back.
;; ============================================================================
PIO_BUF   equ 264           ; the 256-byte buffer, ending here
PIO_FD    equ 272           ; below it, so neither can grow into the other
PIO_LEN   equ 280
PIO_FRAME equ 288           ; + 2 pushes = 304, 16-aligned
PIO_MAX   equ 256

DEF_FUNC posix_ioctl, PIO_FRAME
    cmp rsi, 2
    jb .pio_argerr
    cmp rsi, 3
    ja .pio_argerr
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi

    mov rdi, [rbx]
    call posix_int_arg
    mov [rbp - PIO_FD], rax         ; the fd, across the next conversion
    mov rdi, [rbx + 8]
    call posix_int_arg
    mov r11, rax                    ; the request

    cmp r12, 3
    jb .pio_int_arg
    mov rdi, [rbx + 16]
    V_TEST_PTR rdi, rax
    ja .pio_int_arg                 ; an immediate: an integer argument
    test rdi, rdi
    jz .pio_int_arg
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel bytes_type]
    cmp rax, rcx
    je .pio_bytes
    extern bytearray_type
    lea rcx, [rel bytearray_type]
    cmp rax, rcx
    jne .pio_int_arg
    mov rsi, [rdi + PyByteArrayObject.ob_bytes]
    mov rdx, [rdi + PyByteArrayObject.ob_size]
    jmp .pio_have_buf
.pio_bytes:
    lea rsi, [rdi + PyBytesObject.data]
    mov rdx, [rdi + PyBytesObject.ob_size]
.pio_have_buf:
    cmp rdx, PIO_MAX
    ja .pio_too_big
    mov [rbp - PIO_LEN], rdx
    push r11
    push r11                        ; two pushes: rsp keeps its alignment
    lea rdi, [rbp - PIO_BUF]
    extern ap_memcpy
    call ap_memcpy
    pop r11
    pop r11

    mov rdi, [rbp - PIO_FD]
    mov rsi, r11
    lea rdx, [rbp - PIO_BUF]
    call sys_ioctl
    test rax, rax
    js .pio_failed
    lea rdi, [rbp - PIO_BUF]
    mov rsi, [rbp - PIO_LEN]
    extern bytes_from_data
    call bytes_from_data
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

.pio_int_arg:
    xor edx, edx
    cmp r12, 3
    jb .pio_call
    mov rdi, [rbx + 16]
    call posix_int_arg
    mov rdx, rax
.pio_call:
    mov rdi, [rbp - PIO_FD]
    mov rsi, r11
    call sys_ioctl
    test rax, rax
    js .pio_failed
    mov edx, TAG_SMALLINT
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.pio_failed:
    neg eax
    mov edi, eax
    xor esi, esi
    extern raise_oserror
    call raise_oserror
.pio_too_big:
    pop r12
    pop rbx
    RAISE exc_ValueError_type, "ioctl buffer is too long"
.pio_argerr:
    RAISE exc_TypeError_type, "ioctl() takes 2 or 3 arguments"
END_FUNC posix_ioctl

;; ============================================================================
;; posix.isatty(fd) -> bool
;;
;; Asks the kernel with TCGETS.  Assuming fd <= 2 is a terminal answers True
;; for a redirected stdout, which is exactly when a program checks.  Errors
;; are not raised: CPython's isatty answers False for a closed or invalid
;; descriptor rather than raising.
;; ============================================================================
PIT_BUF   equ 80            ; struct termios is 60 bytes
PIT_FRAME equ 80            ; + 0 pushes = 80

DEF_FUNC posix_isatty, PIT_FRAME
    test rsi, rsi
    jz .pit_argerr
    mov rdi, [rdi]
    call posix_int_arg
    mov rdi, rax
    mov esi, TCGETS
    lea rdx, [rbp - PIT_BUF]
    call sys_ioctl
    test rax, rax
    js .pit_false
    lea rax, [rel bool_true]
    jmp .pit_out
.pit_false:
    lea rax, [rel bool_false]
.pit_out:
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    ret
.pit_argerr:
    RAISE exc_TypeError_type, "isatty() takes exactly 1 argument"
END_FUNC posix_isatty

;; ============================================================================
;; posix.ftruncate(fd, length)
;; ============================================================================
DEF_FUNC posix_ftruncate, 8         ; lint: pushes=1 -- the `push rbx` below sits after the
                            ; argument test, and lint counts only the pushes before
                            ; the first non-push instruction.  Unannotated it read
                            ; this frame as pushless and demanded the size that
                            ; MISALIGNS it.
    cmp rsi, 2
    jl .pft_argerr
    push rbx
    mov rbx, rdi
    mov rdi, [rbx]
    call posix_int_arg
    push rax
    push rax
    mov rdi, [rbx + 8]
    call posix_int_arg
    mov rsi, rax
    pop rdi
    pop rdi
    call sys_ftruncate
    POSIX_CHECK rax, 0
    LOAD_NONE rax
    mov edx, TAG_PTR
    pop rbx
    leave
    ret
.pft_argerr:
    RAISE exc_TypeError_type, "ftruncate() takes exactly 2 arguments"
END_FUNC posix_ftruncate


;; ============================================================================
;; The rest of the file-system calls the module was short of: truncate, link,
;; chown, fchmod, fsync, dup2 and utime.
;;
;; bugs.md listed ftruncate among the missing ones; ftruncate was here and
;; `truncate` -- the path-taking form, which is what shutil and tempfile
;; reach for -- was not.
;; ============================================================================

;; posix.truncate(path, length)
PTR_PATH  equ 8
PTR_OWNED equ 16
PTR_LEN   equ 24
PTR_FRAME equ 40            ; + 1 push = 48, 16-aligned
DEF_FUNC posix_truncate, PTR_FRAME
    push rbx
    cmp rsi, 2
    jl .ptr_argerr
    mov rbx, rdi
    ; The length is converted first: a raise abandons the C stack, and doing
    ; it after the path would strand whatever __fspath__ built.
    mov rdi, [rbx + 8]
    call posix_int_arg
    mov [rbp - PTR_LEN], rax
    mov rdi, [rbx]
    mov [rbp - PTR_PATH], rdi
    CSTRING rsi, "truncate: path"
    mov edx, POSIX_PATH_KIND_PLAIN
    call posix_path_arg
    test rax, rax
    jz .ptr_fail
    mov [rbp - PTR_OWNED], rdx
    mov rdi, rax
    mov rsi, [rbp - PTR_LEN]
    call sys_truncate
    POSIX_PATH_CHECK rax, [rbp - PTR_PATH], [rbp - PTR_OWNED]
    LOAD_NONE rax
    mov edx, TAG_PTR
    pop rbx
    leave
    ret
.ptr_fail:
    xor eax, eax
    xor edx, edx
    pop rbx
    leave
    ret
.ptr_argerr:
    pop rbx
    PM_MISSING "truncate", "length", 2
END_FUNC posix_truncate

;; posix.link(src, dst)
PLK_SRC   equ 8
PLK_SOWN  equ 16
PLK_SPTR  equ 24
PLK_DST   equ 32
PLK_DOWN  equ 40
PLK_FRAME equ 56            ; + 1 push = 64, 16-aligned
DEF_FUNC posix_link, PLK_FRAME
    push rbx
    cmp rsi, 2
    jl .plk_argerr
    mov rbx, rdi
    mov qword [rbp - PLK_SOWN], 0
    mov qword [rbp - PLK_DOWN], 0
    mov rdi, [rbx]
    mov [rbp - PLK_SRC], rdi
    CSTRING rsi, "link: src"
    mov edx, POSIX_PATH_KIND_PLAIN
    call posix_path_arg
    test rax, rax
    jz .plk_fail
    mov [rbp - PLK_SPTR], rax
    mov [rbp - PLK_SOWN], rdx
    mov rdi, [rbx + 8]
    mov [rbp - PLK_DST], rdi
    CSTRING rsi, "link: dst"
    mov edx, POSIX_PATH_KIND_PLAIN
    call posix_path_arg
    test rax, rax
    jz .plk_fail
    mov [rbp - PLK_DOWN], rdx
    mov rsi, rax
    mov rdi, [rbp - PLK_SPTR]
    call sys_link
    ; Both paths stay alive across the check: the message names them both.
    cmp rax, -4095
    jb .plk_ok
    mov rdi, rax
    neg rdi
    mov rsi, [rbp - PLK_SRC]
    mov rdx, [rbp - PLK_SOWN]
    mov rcx, [rbp - PLK_DST]
    mov r8, [rbp - PLK_DOWN]
    extern raise_oserror_owned2
    call raise_oserror_owned2   ; does not return
.plk_ok:
    call .plk_release
    LOAD_NONE rax
    mov edx, TAG_PTR
    pop rbx
    leave
    ret
.plk_release:
    mov rdi, [rbp - PLK_SOWN]
    test rdi, rdi
    jz .plk_rel_d
    mov qword [rbp - PLK_SOWN], 0
    call obj_decref
.plk_rel_d:
    mov rdi, [rbp - PLK_DOWN]
    test rdi, rdi
    jz .plk_rel_done
    mov qword [rbp - PLK_DOWN], 0
    call obj_decref
.plk_rel_done:
    ret
.plk_fail:
    call .plk_release
    xor eax, eax
    xor edx, edx
    pop rbx
    leave
    ret
.plk_argerr:
    pop rbx
    PM_MISSING "link", "dst", 2
END_FUNC posix_link

;; posix.chown(path, uid, gid)
PCH_PATH  equ 8
PCH_OWNED equ 16
PCH_UID   equ 24
PCH_GID   equ 32
PCH_FRAME equ 56            ; + 1 push = 64, 16-aligned
DEF_FUNC posix_chown, PCH_FRAME
    push rbx
    cmp rsi, 3
    jl .pch_argerr
    mov rbx, rdi
    mov rdi, [rbx + 8]
    call posix_int_arg
    mov [rbp - PCH_UID], rax
    mov rdi, [rbx + 16]
    call posix_int_arg
    mov [rbp - PCH_GID], rax
    mov rdi, [rbx]
    mov [rbp - PCH_PATH], rdi
    CSTRING rsi, "chown: path"
    mov edx, POSIX_PATH_KIND_PLAIN
    call posix_path_arg
    test rax, rax
    jz .pch_fail
    mov [rbp - PCH_OWNED], rdx
    mov rdi, rax
    mov rsi, [rbp - PCH_UID]
    mov rdx, [rbp - PCH_GID]
    call sys_chown
    POSIX_PATH_CHECK rax, [rbp - PCH_PATH], [rbp - PCH_OWNED]
    LOAD_NONE rax
    mov edx, TAG_PTR
    pop rbx
    leave
    ret
.pch_fail:
    xor eax, eax
    xor edx, edx
    pop rbx
    leave
    ret
.pch_argerr:
    pop rbx
    PM_MISSING "chown", "gid", 3
END_FUNC posix_chown

;; The three that take descriptors and no path.
%macro POSIX_FD_ONLY 5          ; %1 = name, %2 = the syscall,
                                ; %3/%4/%5 = the clinic message's three parts
DEF_FUNC %1, 16
    test rsi, rsi
    jz %%argerr
    mov rdi, [rdi]
    call posix_int_arg
    mov rdi, rax
    call %2
    POSIX_CHECK rax, 0
    LOAD_NONE rax
    mov edx, TAG_PTR
    leave
    ret
%%argerr:
    PM_MISSING %3, %4, %5
END_FUNC %1
%endmacro
POSIX_FD_ONLY posix_fsync, sys_fsync, "fsync", "fd", 1

;; The two that take a descriptor and one more integer.
%macro POSIX_FD_INT 5           ; %1 = name, %2 = the syscall,
                                ; %3/%4/%5 = the clinic message's three parts
DEF_FUNC %1, 16
    cmp rsi, 2
    jl %%argerr
    push rbx
    mov rbx, rdi
    mov rdi, [rbx]
    call posix_int_arg
    push rax
    push rax
    mov rdi, [rbx + 8]
    call posix_int_arg
    mov rsi, rax
    pop rdi
    pop rdi
    call %2
    POSIX_CHECK rax, 0
    LOAD_NONE rax
    mov edx, TAG_PTR
    pop rbx
    leave
    ret
%%argerr:
    PM_MISSING %3, %4, %5
END_FUNC %1
%endmacro
POSIX_FD_INT posix_fchmod, sys_fchmod, "fchmod", "mode", 2

;; posix.dup2(fd, fd2) -> fd2.  Unlike the others this ANSWERS the descriptor.
DEF_FUNC posix_dup2, 8         ; lint: pushes=1 -- the `push rbx` below sits after the
                            ; argument test, and lint counts only the pushes before
                            ; the first non-push instruction.  Unannotated it read
                            ; this frame as pushless and demanded the size that
                            ; MISALIGNS it.
    cmp rsi, 2
    jl .pd2_argerr
    push rbx
    mov rbx, rdi
    mov rdi, [rbx]
    call posix_int_arg
    push rax
    push rax
    mov rdi, [rbx + 8]
    call posix_int_arg
    mov rsi, rax
    pop rdi
    pop rdi
    call sys_dup2
    POSIX_CHECK rax, 0
    mov edx, TAG_SMALLINT
    pop rbx
    leave
    V_PACK rax, rdx
    ret
.pd2_argerr:
    PM_MISSING "dup2", "fd2", 2
END_FUNC posix_dup2
;;
;; The argv array is built on the machine stack rather than the heap: this
;; runs in a freshly forked child, where the allocator's locks belong to a
;; thread that no longer exists.  There is one thread here, so that is
;; theatre -- but the array has to outlive nothing, and the stack is where it
;; naturally goes.
;; ============================================================================
; The vector grows UPWARD from its base, so its slot is the DEEPEST one --
; naming it 32 put the first pointer over PXV_ARGS and the second over
; PXV_PATH.
;; posix.utime(path, times=None)
;;
;; utimensat is the only member of the family Linux still keeps.  A NULL
;; times means "now", which is what utime(path) alone does; a two-element
;; (atime, mtime) is converted to the pair of timespecs it wants.
PUT_PATH  equ 8
PUT_OWNED equ 16
PUT_TIMES equ 48            ; two struct timespec, 16 bytes each
PUT_FRAME equ 72            ; + 1 push = 80, 16-aligned
DEF_FUNC posix_utime, PUT_FRAME
    push rbx
    test rsi, rsi
    jz .put_argerr
    mov rbx, rdi
    mov r8, rsi

    ; A NULL times argument is "set both to now".
    xor r9d, r9d
    cmp r8, 2
    jl .put_have_times
    mov rdi, [rbx + 8]
    lea rax, [rel none_singleton]
    cmp rdi, rax
    je .put_have_times
    ; A two-element sequence of seconds.  Fractional seconds are accepted and
    ; truncated, as CPython's utime(path, (a, m)) does for a float pair.
    V_TEST_PTR rdi, rax
    ja .put_bad_times
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel tuple_type]
    cmp rax, rcx
    jne .put_bad_times
    cmp qword [rdi + PyTupleObject.ob_size], 2
    jne .put_bad_times
    mov rax, [rdi + PyTupleObject.ob_item]
    push rax
    mov rdi, [rax]
    call posix_time_seconds
    mov [rbp - PUT_TIMES], rax
    mov qword [rbp - PUT_TIMES + 8], 0
    pop rax
    push rax
    mov rdi, [rax + 8]
    call posix_time_seconds
    mov [rbp - PUT_TIMES + 16], rax
    mov qword [rbp - PUT_TIMES + 24], 0
    pop rax
    lea r9, [rbp - PUT_TIMES]

.put_have_times:
    mov [rbp - PUT_OWNED], r9   ; parked across posix_path_arg
    mov rdi, [rbx]
    mov [rbp - PUT_PATH], rdi
    CSTRING rsi, "utime: path"
    mov edx, POSIX_PATH_KIND_PLAIN
    call posix_path_arg
    test rax, rax
    jz .put_fail
    mov r9, [rbp - PUT_OWNED]
    mov [rbp - PUT_OWNED], rdx
    mov rsi, rax
    mov edi, -100               ; AT_FDCWD
    mov rdx, r9
    xor ecx, ecx
    call sys_utimensat
    ; CPython's utime does not put the filename in the OSError, unlike every
    ; other path call here, so neither does this.
    push rax
    mov rdi, [rbp - PUT_OWNED]
    test rdi, rdi
    jz .put_no_release
    mov qword [rbp - PUT_OWNED], 0
    call obj_decref
.put_no_release:
    pop rax
    POSIX_CHECK rax, 0
    LOAD_NONE rax
    mov edx, TAG_PTR
    pop rbx
    leave
    ret
.put_fail:
    xor eax, eax
    xor edx, edx
    pop rbx
    leave
    ret
.put_bad_times:
    pop rbx
    RAISE exc_TypeError_type, "utime: 'times' must be either a tuple of two ints or None"
.put_argerr:
    pop rbx
    PM_MISSING "utime", "path", 1
END_FUNC posix_utime

;; posix_time_seconds(rdi = a Value) -> rax = whole seconds
;; An int stays exact; a float truncates toward zero.
DEF_FUNC_LOCAL posix_time_seconds
    V_IS_FLOAT rdi, rax
    ja .pts_int
    V_TO_F64 rdi
    movq xmm0, rdi
    cvttsd2si rax, xmm0
    leave
    ret
.pts_int:
    call posix_int_arg
    leave
    ret
END_FUNC posix_time_seconds

;; ============================================================================
;; posix.get_inheritable(fd) -> bool   /   posix.set_inheritable(fd, bool)
;;
;; Inheritance across exec is the INVERSE of the close-on-exec flag, which is
;; where the negation below comes from.  FileIO's constructor calls
;; set_inheritable(fd, False) on every descriptor it opens.
;; ============================================================================
DEF_FUNC posix_get_inheritable, 16
    test rsi, rsi
    jz .pgi_argerr
    mov rdi, [rdi]
    call posix_int_arg
    mov rdi, rax
    mov esi, F_GETFD
    xor edx, edx
    call sys_fcntl
    POSIX_CHECK rax, 0
    test eax, FD_CLOEXEC
    jnz .pgi_false              ; close-on-exec set => NOT inheritable
    lea rax, [rel bool_true]
    jmp .pgi_out
.pgi_false:
    lea rax, [rel bool_false]
.pgi_out:
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    ret
.pgi_argerr:
    RAISE exc_TypeError_type, "get_inheritable() takes exactly 1 argument"
END_FUNC posix_get_inheritable

PSI_FD    equ 8
PSI_WANT  equ 16
PSI_FRAME equ 32            ; + 0 pushes = 32

DEF_FUNC posix_set_inheritable, PSI_FRAME
    cmp rsi, 2
    jl .psi_argerr
    mov rsi, [rdi + 8]
    mov rdi, [rdi]
    mov [rbp - PSI_WANT], rsi
    call posix_int_arg
    mov [rbp - PSI_FD], rax

    ; Read the current flags, then set or clear FD_CLOEXEC without disturbing
    ; anything else in the word.
    mov rdi, rax
    mov esi, F_GETFD
    xor edx, edx
    call sys_fcntl
    POSIX_CHECK rax, 0
    mov edx, eax
    mov rdi, [rbp - PSI_WANT]
    call obj_is_true
    test eax, eax
    jz .psi_clear_inherit
    and edx, ~FD_CLOEXEC        ; inheritable: clear close-on-exec
    jmp .psi_apply
.psi_clear_inherit:
    or edx, FD_CLOEXEC
.psi_apply:
    mov rdi, [rbp - PSI_FD]
    mov esi, F_SETFD
    call sys_fcntl
    POSIX_CHECK rax, 0
    LOAD_NONE rax
    mov edx, TAG_PTR
    leave
    ret
.psi_argerr:
    RAISE exc_TypeError_type, "set_inheritable() takes exactly 2 arguments"
END_FUNC posix_set_inheritable

;; ============================================================================
;; posix.device_encoding(fd) -> None
;;
;; CPython answers the console's encoding on Windows and None on POSIX unless
;; the descriptor is a terminal, in which case it reports the locale's.  There
;; is no locale here, so None -- which is what _pyio then falls back from.
;; ============================================================================
DEF_FUNC posix_device_encoding, 16
    test rsi, rsi
    jz .pde_argerr
    LOAD_NONE rax
    mov edx, TAG_PTR
    leave
    ret
.pde_argerr:
    RAISE exc_TypeError_type, "device_encoding() takes exactly 1 argument"
END_FUNC posix_device_encoding

;; ============================================================================
;; posix.uname() -> uname_result
;;
;; Five of struct utsname's six fixed 65-byte fields; the sixth, domainname,
;; is a GNU extension CPython does not report.  platform.system() reads
;; sysname, which is why platform reported "linux" from sys.platform instead
;; of "Linux" without this.
;; ============================================================================
PUN_BUF   equ UTSNAME_SIZE + 16
PUN_OBJ   equ UTSNAME_SIZE + 24
; Rounded up to a multiple of 16 as well as derived: UTSNAME_SIZE is 390, so
; UTSNAME_SIZE + 32 left rsp two bytes off any alignment at all across the
; five calls below, and glibc's SSE paths want sixteen.
PUN_FRAME equ ((UTSNAME_SIZE + 32 + 15) / 16) * 16
DEF_FUNC posix_uname, PUN_FRAME
    push rbx
    lea rdi, [rbp - PUN_BUF]
    call sys_uname
    POSIX_CHECK rax, 0

    lea rdi, [rel uname_result_type]
    call structseq_init_type
    lea rdi, [rel uname_result_type]
    call structseq_new
    test rax, rax
    jz .pun_fail
    mov [rbp - PUN_OBJ], rax

    xor ebx, ebx
.pun_loop:
    cmp rbx, 5
    jge .pun_done
    mov rax, rbx
    imul rax, UTSNAME_FIELD
    lea rdi, [rbp - PUN_BUF]
    add rdi, rax
    call str_from_cstr_heap
    mov rdx, rax
    mov rdi, [rbp - PUN_OBJ]
    mov esi, ebx
    call structseq_set          ; takes over the reference
    inc rbx
    jmp .pun_loop
.pun_done:
    mov rax, [rbp - PUN_OBJ]
    mov edx, TAG_PTR
    pop rbx
    leave
    ret
.pun_fail:
    xor eax, eax
    xor edx, edx
    pop rbx
    leave
    ret
END_FUNC posix_uname

;; posix.strerror(errno) -> str
DEF_FUNC posix_strerror, 16
    test rsi, rsi
    jz .pse_argerr
    mov rdi, [rdi]
    call posix_int_arg
    mov edi, eax
    call strerror wrt ..plt
    mov rdi, rax
    call str_from_cstr_heap
    leave
    ret
.pse_argerr:
    RAISE exc_TypeError_type, "strerror() takes exactly 1 argument"
END_FUNC posix_strerror

;; posix.urandom(n) -> bytes
PUR_BUF   equ 8
PUR_N     equ 16
PUR_FRAME equ 32            ; + 0 pushes = 32

DEF_FUNC posix_urandom, PUR_FRAME
    test rsi, rsi
    jz .pur_argerr
    mov rdi, [rdi]
    call posix_int_arg
    test rax, rax
    js .pur_negative
    mov [rbp - PUR_N], rax
    mov rdi, rax
    test rdi, rdi
    jnz .pur_alloc
    mov edi, 1
.pur_alloc:
    call ap_malloc
    test rax, rax
    jz .pur_fail
    mov [rbp - PUR_BUF], rax
    ; getrandom can return short; loop until the whole buffer is filled.
    xor ecx, ecx
.pur_loop:
    mov rax, [rbp - PUR_N]
    cmp rcx, rax
    jge .pur_wrap
    push rcx
    push rcx
    mov rdi, [rbp - PUR_BUF]
    add rdi, rcx
    mov rsi, [rbp - PUR_N]
    sub rsi, rcx
    xor edx, edx
    call sys_getrandom
    pop rcx
    pop rcx
    cmp rax, -4095
    jb .pur_advance
    push rax
    push rax
    mov rdi, [rbp - PUR_BUF]
    call ap_free
    pop rax
    pop rax
    POSIX_CHECK rax, 0
.pur_advance:
    add rcx, rax
    jmp .pur_loop
.pur_wrap:
    mov rdi, [rbp - PUR_BUF]
    mov rsi, [rbp - PUR_N]
    call bytes_from_data
    push rax
    push rax
    mov rdi, [rbp - PUR_BUF]
    call ap_free
    pop rax
    pop rax
    mov edx, TAG_PTR
    leave
    ret
.pur_negative:
    RAISE exc_ValueError_type, "negative argument not allowed"
.pur_fail:
    xor eax, eax
    xor edx, edx
    leave
    ret
.pur_argerr:
    RAISE exc_TypeError_type, "urandom() takes exactly 1 argument"
END_FUNC posix_urandom

;; posix.fspath(path) -> the path itself, or what __fspath__ gives
PFS_OBJ   equ 8             ; the argument, kept for the message
PFS_EXC   equ 16            ; current_exception before __fspath__ ran
PFS_FRAME equ 16            ; + 0 pushes = 16

DEF_FUNC posix_fspath, PFS_FRAME
    test rsi, rsi
    jz .pfs_argerr
    mov rdi, [rdi]
    ; Kept, because dunder_call_1 below does not preserve rdi and .pfs_bad
    ; used to read it back out of the register afterwards -- a wild pointer
    ; that raise_type_error_with_name then dereferenced.
    mov [rbp - PFS_OBJ], rdi
    mov qword [rbp - PFS_EXC], 0
    V_TEST_PTR rdi, rax
    ja .pfs_bad
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    je .pfs_self
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_STR_SUBCLASS
    jnz .pfs_self
    lea rcx, [rel bytes_type]
    cmp rax, rcx
    je .pfs_self
    CSTRING rsi, "__fspath__"
    DUNDER_EXC_SAVE [rbp - PFS_EXC]
    call dunder_call_1
    test rax, rax               ; dunder_call_1 answers with a Value; 0 is absent-or-raised
    jz .pfs_no_result

    ; What __fspath__ answered has to be a path itself; CPython checks, and
    ; without it `__fspath__` returning an int handed the int straight back.
    V_TEST_PTR rax, rcx
    ja .pfs_bad_result
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    je .pfs_result_ok
    test qword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_STR_SUBCLASS
    jnz .pfs_result_ok
    lea rdx, [rel bytes_type]
    cmp rcx, rdx
    jne .pfs_bad_result
.pfs_result_ok:
    mov edx, TAG_PTR
    leave
    ret
.pfs_self:
    mov rax, rdi
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    ret

.pfs_no_result:
    ; NULL means either "no __fspath__" or "__fspath__ raised", and reporting
    ; the second as a bad path type buries the real exception.
    DUNDER_RAISED [rbp - PFS_EXC], .pfs_propagate
    jmp .pfs_bad
.pfs_propagate:
    xor eax, eax
    xor edx, edx
    leave
    ret

.pfs_bad_result:
    ; The class whose __fspath__ misbehaved, then what it answered -- the
    ; same two-name message posix_path_arg composes.
    push rax                    ; the result, released once its name is copied:
    push rax                    ; twice, to keep rsp 16-byte aligned
    lea rdi, [rel pm_msgbuf]
    lea rsi, [rel pm_msg_expected]
    mov edx, 40
    call posix_copy_bounded
    mov rdi, rax
    mov rsi, [rbp - PFS_OBJ]
    call posix_typename_of
    mov rdi, rax
    lea rsi, [rel pm_msg_fspath]
    mov edx, 60
    call posix_copy_bounded
    mov rdi, rax
    mov rsi, [rsp]
    call posix_typename_of
    pop rdi
    pop rdi
    DECREF_V rdi, rcx           ; a Value: __fspath__ may answer an immediate
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel pm_msgbuf]
    call raise_exception
    ud2

.pfs_bad:
    mov rsi, [rbp - PFS_OBJ]
    CSTRING rdi, `expected str, bytes or os.PathLike object, not \x01`
    call raise_type_error_with_name
.pfs_argerr:
    RAISE exc_TypeError_type, "fspath() takes exactly 1 argument"
END_FUNC posix_fspath

;; ============================================================================
;; posix.environ, a dict[bytes, bytes] built from glibc's `environ`.
;;
;; os._createenviron decodes it with sys.getfilesystemencoding() and
;; surrogateescape.  bytes keys are the reason bytes needed a tp_hash first:
;; without one, obj_hash falls through to the object address and every lookup
;; in this dict misses.
;; ============================================================================
PEN_DICT  equ 8
PEN_CUR   equ 16
PEN_KEY   equ 24
PEN_VAL   equ 32
PEN_FRAME equ 32            ; + 1 push = 40

DEF_FUNC posix_environ_new, 40
    push rbx
    call dict_new
    test rax, rax
    jz .pen_out
    mov [rbp - PEN_DICT], rax

    mov rax, [rel environ]
    test rax, rax
    jz .pen_done
    mov [rbp - PEN_CUR], rax

.pen_loop:
    mov rax, [rbp - PEN_CUR]
    mov rbx, [rax]              ; "KEY=VALUE", or NULL at the end
    test rbx, rbx
    jz .pen_done
    add qword [rbp - PEN_CUR], 8

    ; Split at the FIRST '=': a value may contain more of them.
    mov rcx, rbx
.pen_scan:
    movzx eax, byte [rcx]
    test al, al
    jz .pen_loop                ; no '=' at all: not an assignment, skip it
    cmp al, '='
    je .pen_split
    inc rcx
    jmp .pen_scan

.pen_split:
    mov rdi, rbx
    mov rsi, rcx
    sub rsi, rbx                ; the key's length
    push rcx
    push rcx
    call bytes_from_data
    pop rcx
    pop rcx
    test rax, rax
    jz .pen_done
    mov [rbp - PEN_KEY], rax

    lea rdi, [rcx + 1]          ; past the '='
    push rdi
    push rdi
    call ap_strlen
    pop rdi
    pop rdi
    mov rsi, rax
    call bytes_from_data
    test rax, rax
    jz .pen_drop_key
    mov [rbp - PEN_VAL], rax

    mov rdi, [rbp - PEN_DICT]
    mov rsi, [rbp - PEN_KEY]
    mov rdx, [rbp - PEN_VAL]
    call dict_set
    mov rdi, [rbp - PEN_VAL]
    call obj_decref             ; dict_set took its own
.pen_drop_key:
    mov rdi, [rbp - PEN_KEY]
    call obj_decref
    jmp .pen_loop

.pen_done:
    mov rax, [rbp - PEN_DICT]
.pen_out:
    pop rbx
    leave
    ret
END_FUNC posix_environ_new

;; ============================================================================
;; posix_module_create() -> the module
;; ============================================================================
%macro POSIX_ADD_INT 2          ; %1 = name symbol, %2 = the value
    mov rdi, %2
    V_PACK_I64 rdi, rcx
    mov [rbp - PMC_ENT], rdi
    lea rdi, [rel %1]
    call str_from_cstr_heap
    mov [rbp - PMC_KEY], rax
    mov rdi, r12
    mov rsi, rax
    mov rdx, [rbp - PMC_ENT]
    call dict_set               ; clobbers rdx and rcx, so both were parked
    mov rax, [rbp - PMC_ENT]
    DECREF_V rax, rcx           ; not obj_decref: V_PACK may have boxed it
    mov rdi, [rbp - PMC_KEY]
    call obj_decref
%endmacro

%macro POSIX_ADD_OBJ 2          ; %1 = name symbol, %2 = an owned object in rax
    mov [rbp - PMC_ENT], %2
    lea rdi, [rel %1]
    call str_from_cstr_heap
    mov [rbp - PMC_KEY], rax
    mov rdi, r12
    mov rsi, rax
    mov rdx, [rbp - PMC_ENT]
    call dict_set
    mov rdi, [rbp - PMC_ENT]
    call obj_decref
    mov rdi, [rbp - PMC_KEY]
    call obj_decref
%endmacro

PMC_ENT   equ 8
PMC_KEY   equ 16
PMC_MOD   equ 24
PMC_FRAME equ 32            ; + 1 push = 40

DEF_FUNC posix_module_create, 40
    push r12
    call dict_new
    test rax, rax
    jz .pmc_fail
    mov r12, rax                ; MODULE_ADD_FUNC wants the dict here

    MODULE_ADD_FUNC posix_stat, pm_n_stat
    MODULE_ADD_FUNC posix_lstat, pm_n_lstat
    MODULE_ADD_FUNC posix_fstat, pm_n_fstat
    MODULE_ADD_FUNC posix_listdir, pm_n_listdir
    extern posixproc_register_env
    mov rdi, r12
    call posixproc_register_env ; putenv and unsetenv, from posixproc.asm
    extern posixdir_register
    mov rdi, r12
    call posixdir_register      ; scandir and DirEntry, from posixdir.asm
    extern posixid_register
    mov rdi, r12
    call posixid_register       ; the credentials and the constants, from
                                ; posixid.asm
    MODULE_ADD_FUNC posix_getcwd, pm_n_getcwd
    MODULE_ADD_FUNC posix_getcwdb, pm_n_getcwdb
    MODULE_ADD_FUNC posix_open, pm_n_open
    MODULE_ADD_FUNC posix_close, pm_n_close
    MODULE_ADD_FUNC posix_read, pm_n_read
    MODULE_ADD_FUNC posix_write, pm_n_write
    MODULE_ADD_FUNC posix_lseek, pm_n_lseek
    MODULE_ADD_FUNC posix_dup, pm_n_dup
    MODULE_ADD_FUNC posix_access, pm_n_access
    MODULE_ADD_FUNC posix_fspath, pm_n_fspath
    MODULE_ADD_FUNC posix_unlink, pm_n_unlink
    MODULE_ADD_FUNC posix_unlink, pm_n_remove      ; os.remove IS unlink
    MODULE_ADD_FUNC posix_mkdir, pm_n_mkdir
    MODULE_ADD_FUNC posix_rmdir, pm_n_rmdir
    MODULE_ADD_FUNC posix_rename, pm_n_rename
    MODULE_ADD_FUNC posix_symlink, pm_n_symlink
    MODULE_ADD_FUNC posix_rename, pm_n_replace     ; rename(2) already replaces
    MODULE_ADD_FUNC posix_chmod, pm_n_chmod
    MODULE_ADD_FUNC posix_readlink, pm_n_readlink
    MODULE_ADD_FUNC posix_pipe, pm_n_pipe
    MODULE_ADD_FUNC posix_getpid, pm_n_getpid
    MODULE_ADD_FUNC posix_umask, pm_n_umask
    MODULE_ADD_FUNC posix_isatty, pm_n_isatty
    MODULE_ADD_FUNC posix_ioctl, pm_n_ioctl
    extern posix_fcntl
    MODULE_ADD_FUNC posix_fcntl, pm_n_fcntl
    extern posix_flock
    MODULE_ADD_FUNC posix_flock, pm_n_flock
    extern posix_prlimit
    MODULE_ADD_FUNC posix_prlimit, pm_n_prlimit
    extern posix_getrusage
    MODULE_ADD_FUNC posix_getrusage, pm_n_getrusage
    MODULE_ADD_FUNC posix_ftruncate, pm_n_ftruncate
    MODULE_ADD_FUNC posix_chdir, pm_n_chdir
    MODULE_ADD_FUNC posix_truncate, pm_n_truncate
    MODULE_ADD_FUNC posix_link, pm_n_link
    MODULE_ADD_FUNC posix_chown, pm_n_chown
    MODULE_ADD_FUNC posix_fchmod, pm_n_fchmod
    MODULE_ADD_FUNC posix_fsync, pm_n_fsync
    MODULE_ADD_FUNC posix_dup2, pm_n_dup2
    ; The three fork-hook lists.  Built here rather than lazily so that
    ; register_at_fork and fork can both assume they exist.
    xor edi, edi
    call list_new
    mov [rel pm_atfork_before], rax
    xor edi, edi
    call list_new
    mov [rel pm_atfork_parent], rax
    xor edi, edi
    call list_new
    mov [rel pm_atfork_child], rax

    MODULE_ADD_FUNC posix_fork, pm_n_fork
    MODULE_ADD_FUNC posix_register_at_fork, pm_n_reg_at_fork
    MODULE_ADD_FUNC posix_execv, pm_n_execv
    ; execve is the same function: it takes the environment as a third
    ; argument, and execv is that call with the argument left off.
    MODULE_ADD_FUNC posix_execv, pm_n_execve
    MODULE_ADD_FUNC posix_close_range, pm_n_close_range
    MODULE_ADD_FUNC posix_exit_now, pm_n_exit_now
    MODULE_ADD_FUNC posix_kill, pm_n_kill
    MODULE_ADD_FUNC posix_setsid, pm_n_setsid
    MODULE_ADD_FUNC posix_utime, pm_n_utime
    MODULE_ADD_FUNC posix_get_inheritable, pm_n_get_inheritable
    MODULE_ADD_FUNC posix_set_inheritable, pm_n_set_inheritable
    MODULE_ADD_FUNC posix_device_encoding, pm_n_device_encoding
    MODULE_ADD_FUNC posix_uname, pm_n_uname
    MODULE_ADD_FUNC posix_strerror, pm_n_strerror
    MODULE_ADD_FUNC posix_urandom, pm_n_urandom
    MODULE_ADD_FUNC posix_waitpid, pm_n_waitpid
    MODULE_ADD_FUNC posix_waitstatus_to_exitcode, pm_n_waitstatus
    MODULE_ADD_FUNC posix_wexitstatus, pm_n_wexitstatus
    MODULE_ADD_FUNC posix_wtermsig, pm_n_wtermsig
    MODULE_ADD_FUNC posix_wstopsig, pm_n_wstopsig
    MODULE_ADD_FUNC posix_wifexited, pm_n_wifexited
    MODULE_ADD_FUNC posix_wifstopped, pm_n_wifstopped
    MODULE_ADD_FUNC posix_wifsignaled, pm_n_wifsignaled
    MODULE_ADD_FUNC posix_wifcontinued, pm_n_wifcontinued
    MODULE_ADD_FUNC posix_wcoredump, pm_n_wcoredump

    ; --- the constants ---
    POSIX_ADD_INT pm_n_O_RDONLY,    O_RDONLY
    POSIX_ADD_INT pm_n_O_WRONLY,    O_WRONLY
    POSIX_ADD_INT pm_n_O_RDWR,      O_RDWR
    POSIX_ADD_INT pm_n_O_ACCMODE,   O_ACCMODE
    POSIX_ADD_INT pm_n_O_CREAT,     O_CREAT
    POSIX_ADD_INT pm_n_O_EXCL,      O_EXCL
    POSIX_ADD_INT pm_n_O_NOCTTY,    O_NOCTTY
    POSIX_ADD_INT pm_n_O_TRUNC,     O_TRUNC
    POSIX_ADD_INT pm_n_O_APPEND,    O_APPEND
    POSIX_ADD_INT pm_n_O_NONBLOCK,  O_NONBLOCK
    POSIX_ADD_INT pm_n_O_DIRECTORY, O_DIRECTORY
    POSIX_ADD_INT pm_n_O_NOFOLLOW,  O_NOFOLLOW
    POSIX_ADD_INT pm_n_O_CLOEXEC,   O_CLOEXEC
    POSIX_ADD_INT pm_n_O_TMPFILE,   O_TMPFILE
    POSIX_ADD_INT pm_n_F_OK,        F_OK
    POSIX_ADD_INT pm_n_R_OK,        R_OK
    POSIX_ADD_INT pm_n_W_OK,        W_OK
    POSIX_ADD_INT pm_n_X_OK,        X_OK
    POSIX_ADD_INT pm_n_SEEK_SET,    SEEK_SET
    POSIX_ADD_INT pm_n_SEEK_CUR,    SEEK_CUR
    POSIX_ADD_INT pm_n_SEEK_END,    SEEK_END
    POSIX_ADD_INT pm_n_WNOHANG,     WNOHANG
    POSIX_ADD_INT pm_n_WUNTRACED,   WUNTRACED
    POSIX_ADD_INT pm_n_WCONTINUED,  WCONTINUED

    ; --- stat_result, and posix.error, which IS OSError ---
    lea rdi, [rel stat_result_type]
    call structseq_init_type
    lea rdi, [rel terminal_size_type]
    call structseq_init_type

    lea rax, [rel stat_result_type]
    inc qword [rax + PyObject.ob_refcnt]
    POSIX_ADD_OBJ pm_n_stat_result, rax
    lea rax, [rel terminal_size_type]
    inc qword [rax + PyObject.ob_refcnt]
    POSIX_ADD_OBJ pm_n_terminal_size, rax
    lea rdi, [rel uname_result_type]
    call structseq_init_type
    lea rax, [rel uname_result_type]
    inc qword [rax + PyObject.ob_refcnt]
    POSIX_ADD_OBJ pm_n_uname_result, rax
    lea rax, [rel exc_OSError_type]
    inc qword [rax + PyObject.ob_refcnt]
    POSIX_ADD_OBJ pm_n_error, rax

    ; --- environ ---
    call posix_environ_new
    test rax, rax
    jz .pmc_no_environ
    POSIX_ADD_OBJ pm_n_environ, rax
.pmc_no_environ:

    ; --- _have_functions, which os.py needs even when empty ---
    ; os.py:442 uses supports_dir_fd and supports_fd unconditionally, and both
    ; are defined only inside `if _exists("_have_functions")`.  An empty list
    ; is the honest answer: no dir_fd= support here.
    xor edi, edi
    call list_new
    test rax, rax
    jz .pmc_no_have
    POSIX_ADD_OBJ pm_n_have_functions, rax
.pmc_no_have:

    ; --- wrap the dict in the module ---
    lea rdi, [rel pm_n_posix]
    call str_from_cstr_heap
    mov [rbp - PMC_KEY], rax
    mov rdi, rax
    mov rsi, r12
    call module_new
    mov [rbp - PMC_MOD], rax
    mov rdi, [rbp - PMC_KEY]
    call obj_decref
    mov rdi, r12
    call obj_decref             ; module_new took its own reference to the dict
    mov rax, [rbp - PMC_MOD]
    pop r12
    leave
    ret

.pmc_fail:
    xor eax, eax
    pop r12
    leave
    ret
END_FUNC posix_module_create

;; ============================================================================
;; The two struct-sequence types.
;; ============================================================================
section .rodata

pm_n_posix:      db "posix", 0
pm_n_stat:       db "stat", 0
pm_n_lstat:      db "lstat", 0
pm_n_fstat:      db "fstat", 0
pm_n_listdir:    db "listdir", 0
pm_n_getcwd:     db "getcwd", 0
pm_n_getcwdb:    db "getcwdb", 0
pm_n_open:       db "open", 0
pm_n_close:      db "close", 0
pm_n_read:       db "read", 0
pm_n_write:      db "write", 0
pm_n_lseek:      db "lseek", 0
pm_n_dup:        db "dup", 0
pm_n_access:     db "access", 0
pm_n_fspath:     db "fspath", 0
pm_n_unlink:     db "unlink", 0
pm_n_remove:     db "remove", 0
pm_n_mkdir:      db "mkdir", 0
pm_n_rmdir:      db "rmdir", 0
pm_n_rename:     db "rename", 0
pm_n_symlink:    db "symlink", 0
pm_n_replace:    db "replace", 0
pm_n_chmod:      db "chmod", 0
pm_n_readlink:   db "readlink", 0
pm_n_pipe:       db "pipe", 0
pm_n_getpid:     db "getpid", 0
pm_int_required: db " object cannot be interpreted as an integer", 0

section .bss
global pm_msgbuf
pm_msgbuf: resb 192

section .rodata
pm_name_int:     db "int", 0
pm_name_float:   db "float", 0
global pm_msg_expected
pm_msg_expected: db "expected ", 0
global pm_msg_path
pm_msg_path:     db "path", 0
global pm_msg_shouldbe
pm_msg_shouldbe: db " should be string, bytes", 0
global pm_kind_plain
pm_kind_plain:   db " or os.PathLike", 0
global pm_kind_fd
pm_kind_fd:      db ", os.PathLike or integer", 0
global pm_kind_fd_none
pm_kind_fd_none: db ", os.PathLike, integer or None", 0
global pm_msg_not
pm_msg_not:      db ", not ", 0
global pm_msg_io
pm_msg_io:       db "expected str, bytes or os.PathLike object, not ", 0
global pm_msg_fspath
pm_msg_fspath:   db ".__fspath__() to return str or bytes, not ", 0
pm_n_umask:      db "umask", 0
pm_n_isatty:     db "isatty", 0
pm_n_ioctl:      db "ioctl", 0
pm_n_fcntl:      db "fcntl", 0
pm_n_flock:      db "flock", 0
pm_n_prlimit:    db "prlimit", 0
pm_n_getrusage:  db "getrusage", 0
pm_n_ftruncate:  db "ftruncate", 0
pm_n_chdir:      db "chdir", 0
pm_n_truncate:   db "truncate", 0
pm_n_link:       db "link", 0
pm_n_chown:      db "chown", 0
pm_n_fchmod:     db "fchmod", 0
pm_n_fsync:      db "fsync", 0
pm_n_dup2:       db "dup2", 0
pm_n_fork:       db "fork", 0
pm_n_reg_at_fork: db "register_at_fork", 0
pm_n_execv:      db "execv", 0
pm_n_execve:     db "execve", 0
pm_n_close_range: db "closerange", 0
pm_n_exit_now:   db "_exit", 0
pm_n_kill:       db "kill", 0
pm_n_setsid:     db "setsid", 0
pm_n_utime:      db "utime", 0
pm_n_get_inheritable: db "get_inheritable", 0
pm_n_set_inheritable: db "set_inheritable", 0
pm_n_device_encoding: db "device_encoding", 0
pm_n_uname:      db "uname", 0
pm_n_uname_result: db "uname_result", 0
pm_n_strerror:   db "strerror", 0
pm_n_urandom:    db "urandom", 0
pm_n_waitpid:    db "waitpid", 0
pm_n_waitstatus: db "waitstatus_to_exitcode", 0
pm_n_wexitstatus: db "WEXITSTATUS", 0
pm_n_wtermsig:   db "WTERMSIG", 0
pm_n_wstopsig:   db "WSTOPSIG", 0
pm_n_wifexited:  db "WIFEXITED", 0
pm_n_wifstopped: db "WIFSTOPPED", 0
pm_n_wifsignaled: db "WIFSIGNALED", 0
pm_n_wifcontinued: db "WIFCONTINUED", 0
pm_n_wcoredump:  db "WCOREDUMP", 0
pm_n_environ:    db "environ", 0
pm_n_error:      db "error", 0
pm_n_stat_result: db "stat_result", 0
pm_n_terminal_size: db "terminal_size", 0
pm_n_have_functions: db "_have_functions", 0

pm_n_O_RDONLY:    db "O_RDONLY", 0
pm_n_O_WRONLY:    db "O_WRONLY", 0
pm_n_O_RDWR:      db "O_RDWR", 0
pm_n_O_ACCMODE:   db "O_ACCMODE", 0
pm_n_O_CREAT:     db "O_CREAT", 0
pm_n_O_EXCL:      db "O_EXCL", 0
pm_n_O_NOCTTY:    db "O_NOCTTY", 0
pm_n_O_TRUNC:     db "O_TRUNC", 0
pm_n_O_APPEND:    db "O_APPEND", 0
pm_n_O_NONBLOCK:  db "O_NONBLOCK", 0
pm_n_O_DIRECTORY: db "O_DIRECTORY", 0
pm_n_O_NOFOLLOW:  db "O_NOFOLLOW", 0
pm_n_O_CLOEXEC:   db "O_CLOEXEC", 0
pm_n_O_TMPFILE:   db "O_TMPFILE", 0
pm_n_F_OK:        db "F_OK", 0
pm_n_R_OK:        db "R_OK", 0
pm_n_W_OK:        db "W_OK", 0
pm_n_X_OK:        db "X_OK", 0
pm_n_SEEK_SET:    db "SEEK_SET", 0
pm_n_SEEK_CUR:    db "SEEK_CUR", 0
pm_n_SEEK_END:    db "SEEK_END", 0
pm_n_WNOHANG:     db "WNOHANG", 0
pm_n_WUNTRACED:   db "WUNTRACED", 0
pm_n_WCONTINUED:  db "WCONTINUED", 0

; --- stat_result ---
sr_name:   db "os.stat_result", 0
sr_f0:  db "st_mode", 0
sr_f1:  db "st_ino", 0
sr_f2:  db "st_dev", 0
sr_f3:  db "st_nlink", 0
sr_f4:  db "st_uid", 0
sr_f5:  db "st_gid", 0
sr_f6:  db "st_size", 0
sr_f7:  db "st_atime", 0
sr_f8:  db "st_mtime", 0
sr_f9:  db "st_ctime", 0
sr_f10: db "st_atime_ns", 0
sr_f11: db "st_mtime_ns", 0
sr_f12: db "st_ctime_ns", 0
sr_f13: db "st_blksize", 0
sr_f14: db "st_blocks", 0
sr_f15: db "st_rdev", 0

align 8
; The three timestamps have TWO storages, as CPython's do: slots 7..9 hold the
; whole seconds and are what the SEQUENCE shows, and slots 16..18 hold the
; float with the fractional part and are what the NAMES resolve to.
; os.stat(p)[8] is an int and os.stat(p).st_mtime is a float, and in CPython
; too they are different objects for the same field.
;
; That is why st_atime, st_mtime and st_ctime appear twice, and why the float
; rows come FIRST: structseq_getattr matches by name and takes the first row
; it finds, while structseq_repr matches by index and finds whichever row
; carries the index it is printing.  So a name resolves to the float and the
; repr prints the whole second, which is what CPython shows.
sr_fields:
    dq sr_f7, 16
    dq sr_f8, 17
    dq sr_f9, 18
    dq sr_f0, 0
    dq sr_f1, 1
    dq sr_f2, 2
    dq sr_f3, 3
    dq sr_f4, 4
    dq sr_f5, 5
    dq sr_f6, 6
    dq sr_f7, 7
    dq sr_f8, 8
    dq sr_f9, 9
    dq sr_f10, 10
    dq sr_f11, 11
    dq sr_f12, 12
    dq sr_f13, 13
    dq sr_f14, 14
    dq sr_f15, 15

align 8
sr_desc:
    dq 10                   ; n_in_sequence: the ten os.stat() shows
    dq 19                   ; n_fields: plus nine reachable by name only
    dq sr_fields

; --- uname_result ---
un_name: db "posix.uname_result", 0
un_f0:   db "sysname", 0
un_f1:   db "nodename", 0
un_f2:   db "release", 0
un_f3:   db "version", 0
un_f4:   db "machine", 0

align 8
un_fields:
    dq un_f0, 0
    dq un_f1, 1
    dq un_f2, 2
    dq un_f3, 3
    dq un_f4, 4

align 8
un_desc:
    dq 5
    dq 5
    dq un_fields

; --- terminal_size ---
ts_name: db "os.terminal_size", 0
ts_f0:   db "columns", 0
ts_f1:   db "lines", 0

align 8
ts_fields:
    dq ts_f0, 0
    dq ts_f1, 1

align 8
ts_desc:
    dq 2
    dq 2
    dq ts_fields

section .data
align 8
global stat_result_type
stat_result_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq sr_name                  ; tp_name
    ; tp_basicsize: the header plus the named-only tail.  Nine now, not six:
    ; the three timestamps have a second storage for their float form, so
    ; os.stat(p)[8] can stay the int CPython puts there.  This has to move
    ; with sr_desc's n_fields, or the last fields are written past the end --
    ; which shows up as a neighbouring field reading as the wrong type, and
    ; then as a double free.
    dq PyTupleObject_size + 9*8 ; tp_basicsize
    dq structseq_dealloc        ; tp_dealloc
    dq structseq_repr           ; tp_repr
    dq structseq_repr           ; tp_str
    dq 0                        ; tp_hash          } copied from tuple_type by
    dq 0                        ; tp_call          } structseq_init_type
    dq structseq_getattr        ; tp_getattr
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq 0                        ; tp_iter
    dq 0                        ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq 0                        ; tp_as_number
    dq 0                        ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq TYPE_FLAG_TUPLE_SUBCLASS ; tp_flags
    dq 0                        ; tp_bases
    dq 0                        ; tp_traverse
    dq 0                        ; tp_clear
    dq 0                        ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer
    dq sr_desc                  ; STRUCTSEQ_DESC

align 8
global uname_result_type
uname_result_type:
    dq 1
    dq type_type
    dq un_name
    dq PyTupleObject_size
    dq structseq_dealloc
    dq structseq_repr
    dq structseq_repr
    dq 0
    dq 0
    dq structseq_getattr
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq TYPE_FLAG_TUPLE_SUBCLASS
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer
    dq un_desc                  ; STRUCTSEQ_DESC, one qword past the type

align 8
global terminal_size_type
terminal_size_type:
    dq 1
    dq type_type
    dq ts_name
    dq PyTupleObject_size
    dq structseq_dealloc
    dq structseq_repr
    dq structseq_repr
    dq 0
    dq 0
    dq structseq_getattr
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0
    dq TYPE_FLAG_TUPLE_SUBCLASS
    dq 0
    dq 0
    dq 0
    dq 0
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer
    dq ts_desc                  ; STRUCTSEQ_DESC, one qword past the type

section .rodata
align 8
psr_1e9: dq 0x41cdcd6500000000     ; 1e9 as IEEE 754 double

