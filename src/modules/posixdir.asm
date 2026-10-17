;; ============================================================================
;; posixdir.asm -- posix.scandir() and posix.DirEntry
;;
;; os.py reaches for scandir and nothing else: walk(), and through it shutil,
;; glob, pathlib and tempfile's cleanup, all end on "name 'scandir' is not
;; defined" without it.
;;
;; What makes scandir worth having over listdir + stat is that getdents64
;; already told us the entry's TYPE, so is_dir() and is_file() usually answer
;; without a syscall.  A DirEntry keeps that d_type and falls back to stat only
;; where the filesystem said DT_UNKNOWN or the question is about the target of
;; a symlink.
;;
;; The directory is read in one pass and the entries handed over as a list the
;; iterator walks, where CPython reads it lazily.  A caller cannot tell the
;; difference except in how long the descriptor is held, and holding it for the
;; length of one getdents64 loop rather than for the length of the caller's
;; body is the safer of the two.
;;
;; It lives in its own file because posix.asm is 300 bytes below the 100k cap.
;; ============================================================================

%include "src/include/object.inc"
%include "src/include/macros.inc"
%include "src/include/value.inc"

; posix_path_arg's kind and its release, both spelled out here rather than
; shared with posix.asm: that file is 200 bytes below the 100k cap and moving
; two definitions into a header would be the whole of a second commit.
POSIX_PATH_KIND_PLAIN equ 0

%macro PD_PATH_DONE 1           ; %1 = a frame slot holding what rdx returned
    push rax
    push rdx
    mov rdi, %1
    test rdi, rdi
    jz %%none
    mov qword %1, 0
    call obj_decref
%%none:
    pop rdx
    pop rax
%endmacro

section .text

extern ap_malloc
extern ap_free
extern builtin_func_new
extern dict_set
extern dict_new
extern dict_add_builtin_func
extern exc_TypeError_type
extern int_from_i64
extern list_append
extern list_new
extern method_new
extern obj_decref
extern obj_is_true
extern posix_path_arg
extern posix_stat_result
extern raise_exception
extern raise_oserror
extern str_concat
extern str_type
extern str_from_cstr_heap
extern posix_name_object
extern bytes_concat
extern bytes_repr
extern bytes_from_data
extern sys_close
extern sys_getdents64
extern sys_lstat
extern sys_open
extern sys_stat
extern ap_strcmp
extern raise_no_attribute
extern none_singleton
extern bool_true
extern bool_false

global direntry_type
global scandir_iter_type
global posix_scandir
global posixdir_register

;; ============================================================================
;; direntry_new(rdi = name str, rsi = path str, rdx = d_type, rcx = d_ino)
;;   -> rax = PyDirEntryObject*, owned, or 0 with an exception pending
;;
;; Takes references of its own on both strings; the caller keeps its.
;; ============================================================================
DEN_NAME  equ 8
DEN_PATH  equ 16
DEN_TYPE  equ 24
DEN_INO   equ 32
DEN_FRAME equ 48            ; + 0 pushes = 48, 16-aligned
DEF_FUNC direntry_new, DEN_FRAME
    mov [rbp - DEN_NAME], rdi
    mov [rbp - DEN_PATH], rsi
    mov [rbp - DEN_TYPE], rdx
    mov [rbp - DEN_INO], rcx

    mov edi, PyDirEntryObject_size
    call ap_malloc
    test rax, rax
    jz .den_out

    mov qword [rax + PyDirEntryObject.ob_refcnt], 1
    lea rcx, [rel direntry_type]
    mov [rax + PyDirEntryObject.ob_type], rcx
    mov rcx, [rbp - DEN_NAME]
    mov [rax + PyDirEntryObject.de_name], rcx
    inc qword [rcx + PyObject.ob_refcnt]
    mov rcx, [rbp - DEN_PATH]
    mov [rax + PyDirEntryObject.de_path], rcx
    inc qword [rcx + PyObject.ob_refcnt]
    mov rcx, [rbp - DEN_TYPE]
    mov [rax + PyDirEntryObject.de_type], rcx
    mov rcx, [rbp - DEN_INO]
    mov [rax + PyDirEntryObject.de_ino], rcx

.den_out:
    leave
    ret
END_FUNC direntry_new

;; ============================================================================
;; direntry_dealloc(rdi = self) -> void
;; ============================================================================
DEF_FUNC direntry_dealloc, 8            ; + 1 push = 16, 16-aligned
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + PyDirEntryObject.de_name]
    test rdi, rdi
    jz .dd_no_name
    call obj_decref
.dd_no_name:
    mov rdi, [rbx + PyDirEntryObject.de_path]
    test rdi, rdi
    jz .dd_no_path
    call obj_decref
.dd_no_path:
    mov rdi, rbx
    call ap_free
    pop rbx
    leave
    ret
END_FUNC direntry_dealloc

;; ============================================================================
;; direntry_repr(rdi = self) -> rax = PyStrObject*, owned, or 0
;; CPython prints <DirEntry 'name'>, with the name repr'd.
;; ============================================================================
DER_SELF  equ 8
DER_PART  equ 16
DER_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
DEF_FUNC direntry_repr, DER_FRAME
    mov [rbp - DER_SELF], rdi

    CSTRING rdi, "<DirEntry "
    call str_from_cstr_heap
    test rax, rax
    jz .drp_out
    mov [rbp - DER_PART], rax

    ; The name's repr, which is its own type's: a bytes entry shows b'x' where
    ; a str entry shows 'x', exactly as CPython's DirEntry repr does.  str_repr
    ; over a bytes would read its header at the wrong offsets.
    mov rdi, [rbp - DER_SELF]
    mov rdi, [rdi + PyDirEntryObject.de_name]
    mov rcx, [rdi + PyObject.ob_type]
    lea rax, [rel str_type]
    cmp rcx, rax
    jne .drp_bytes_name
    extern str_repr
    call str_repr
    jmp .drp_have_name
.drp_bytes_name:
    call bytes_repr
.drp_have_name:
    test rax, rax
    jz .drp_fail_part
    push rax
    mov rdi, [rbp - DER_PART]
    mov rsi, rax
    call str_concat
    mov [rbp - DER_PART], rax
    pop rdi
    push rax
    call obj_decref             ; the quoted name
    pop rax
    test rax, rax
    jz .drp_out

    CSTRING rdi, ">"
    call str_from_cstr_heap
    test rax, rax
    jz .drp_fail_part
    push rax
    mov rdi, [rbp - DER_PART]
    mov rsi, rax
    call str_concat
    mov [rbp - DER_PART], rax
    pop rdi
    push rax
    call obj_decref
    pop rax
    mov rax, [rbp - DER_PART]

.drp_out:
    ; The TAG, which this function never set.  obj_repr TAIL-CALLS tp_repr, so
    ; whatever (rax, edx) this leaves IS obj_repr's answer -- and edx was
    ; whatever the last call happened to leave, which under the pool allocator
    ; was usable and under APYTHON_MALLOC=libc was not: repr(entry) came back
    ; as an int holding the string's ADDRESS.  bytes_repr_impl carries a
    ; comment about the identical trap.
    mov edx, TAG_PTR
    leave
    ret

.drp_fail_part:
    mov rdi, [rbp - DER_PART]
    test rdi, rdi
    jz .drp_zero
    call obj_decref
.drp_zero:
    RET_NULL
    leave
    ret
END_FUNC direntry_repr

;; ============================================================================
;; posixdir_follow_arg(rdi = args, rsi = nargs) -> eax = 1 to follow symlinks
;;
;; follow_symlinks is keyword-only on every DirEntry method and defaults to
;; True.  The keyword names arrive in kw_names_pending, which has to be taken
;; down whether or not the name being looked for is among them.
;; ============================================================================
PFA_ARGS  equ 8
PFA_NARGS equ 16
PFA_NPOS  equ 24
PFA_RES   equ 32
PFA_FRAME equ 48            ; + 1 push = 56 ... see the push below
DEF_FUNC posixdir_follow_arg, PFA_FRAME
    push rbx
    sub rsp, 8                  ; pad: 48 + 8 + 8 = 64, so the calls are aligned
    mov [rbp - PFA_ARGS], rdi
    mov [rbp - PFA_NARGS], rsi
    mov dword [rbp - PFA_RES], 1

    mov rax, [gs:ThreadState.kw_names_pending]
    test rax, rax
    jz .pfa_out
    mov qword [gs:ThreadState.kw_names_pending], 0

    mov rcx, [rax + PyTupleObject.ob_size]
    mov rdx, rsi
    sub rdx, rcx
    mov [rbp - PFA_NPOS], rdx
    mov rbx, [rax + PyTupleObject.ob_item]
    xor r8d, r8d

.pfa_loop:
    cmp r8, rcx
    jge .pfa_out
    push rcx
    push r8
    mov r10, [rbx + r8*8]
    lea rdi, [r10 + PyStrObject.data]
    CSTRING rsi, "follow_symlinks"
    call ap_strcmp
    mov r11d, eax
    pop r8
    pop rcx
    test r11d, r11d
    jnz .pfa_next

    push rcx
    push r8
    mov r10, [rbp - PFA_NPOS]
    add r10, r8
    mov rdi, [rbp - PFA_ARGS]
    mov rdi, [rdi + r10*8]
    call obj_is_true
    pop r8
    pop rcx
    mov [rbp - PFA_RES], eax
    jmp .pfa_out

.pfa_next:
    inc r8
    jmp .pfa_loop

.pfa_out:
    mov eax, [rbp - PFA_RES]
    add rsp, 8
    pop rbx
    leave
    ret
END_FUNC posixdir_follow_arg

;; ============================================================================
;; psd_join(rdi = the prefix, rsi = the name) -> rax = the two joined, or 0
;;
;; Both are the argument's own kind, so the concatenation is chosen from the
;; prefix's type rather than threaded through another argument.  str_concat and
;; bytes_concat both take Values and answer one; a pointer is its own Value.
;; ============================================================================
PJ_FRAME equ 16             ; + 0 pushes = 16, 16-aligned
DEF_FUNC_LOCAL psd_join, PJ_FRAME
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    jne .pj_bytes
    call str_concat
    leave
    ret
.pj_bytes:
    call bytes_concat
    leave
    ret
END_FUNC psd_join

;; ============================================================================
;; direntry_statbuf(rdi = self, esi = follow, rdx = StatBuf*) -> eax
;;   0 = filled in, else the errno
;;
;; The path is the entry's own, so there is no argument conversion to do: it is
;; already the NUL-terminated bytes the syscall wants.  Which KIND it is has to
;; be asked, though: a scandir over a bytes argument builds bytes entries, and
;; PyBytesObject.data is at +24 where PyStrObject.data is at +40 -- reading one
;; at the other's offset is sixteen bytes past the start of the object.
;; ============================================================================
DEF_FUNC_BARE direntry_statbuf
    mov rax, [rdi + PyDirEntryObject.de_path]
    mov rcx, [rax + PyObject.ob_type]
    lea rdi, [rel str_type]
    cmp rcx, rdi
    jne .dsb_bytes_path
    lea rdi, [rax + PyStrObject.data]
    jmp .dsb_have_path
.dsb_bytes_path:
    lea rdi, [rax + PyBytesObject.data]
.dsb_have_path:
    mov rax, rsi
    mov rsi, rdx
    test eax, eax
    jz .dsb_lstat
    call sys_stat
    jmp .dsb_check
.dsb_lstat:
    call sys_lstat
.dsb_check:
    test rax, rax
    jz .dsb_ok
    neg rax
    ret
.dsb_ok:
    xor eax, eax
    ret
END_FUNC direntry_statbuf

;; ============================================================================
;; direntry_kind(rdi = self, esi = follow, edx = the S_IF* wanted)
;;   -> eax = 1 / 0
;;
;; The one body behind is_dir(), is_file() and is_symlink().  d_type answers
;; outright unless the filesystem said DT_UNKNOWN or the entry is a symlink
;; whose target is what was asked about; a stat that fails is False, as
;; CPython's is -- a dangling link is not a file and not a directory.
;; ============================================================================
DK_SELF   equ 8
DK_FOLLOW equ 16
DK_WANT   equ 24
DK_BUF    equ 32 + StatBuf_size
DK_FRAME  equ 32 + StatBuf_size      ; derived, so the buffer cannot overlap
DEF_FUNC direntry_kind, DK_FRAME
    mov [rbp - DK_SELF], rdi
    mov [rbp - DK_FOLLOW], esi
    mov [rbp - DK_WANT], edx

    mov rcx, [rdi + PyDirEntryObject.de_type]

    ; A symlink is a symlink whatever it points at, and it is nothing else
    ; unless the question is about the target.
    cmp rcx, DT_LNK
    jne .dk_not_link
    cmp edx, S_IFLNK
    je .dk_yes
    test esi, esi
    jz .dk_no                       ; not following: it is a link, not a dir
    jmp .dk_stat
.dk_not_link:
    cmp edx, S_IFLNK
    je .dk_maybe_link

    cmp rcx, DT_UNKNOWN
    je .dk_stat
    cmp rcx, DT_DIR
    jne .dk_not_dir
    cmp edx, S_IFDIR
    je .dk_yes
    jmp .dk_no
.dk_not_dir:
    cmp rcx, DT_REG
    jne .dk_no
    cmp edx, S_IFREG
    je .dk_yes
    jmp .dk_no

.dk_maybe_link:
    ; is_symlink() on an entry the filesystem did not classify: only an lstat
    ; can say, and is_symlink() never follows.
    cmp rcx, DT_UNKNOWN
    jne .dk_no
    mov dword [rbp - DK_FOLLOW], 0

.dk_stat:
    mov rdi, [rbp - DK_SELF]
    mov esi, [rbp - DK_FOLLOW]
    lea rdx, [rbp - DK_BUF]
    call direntry_statbuf
    test eax, eax
    jnz .dk_no                      ; a link with no target is neither
    mov eax, [rbp - DK_BUF + StatBuf.st_mode]
    and eax, S_IFMT
    cmp eax, [rbp - DK_WANT]
    jne .dk_no

.dk_yes:
    mov eax, 1
    leave
    ret
.dk_no:
    xor eax, eax
    leave
    ret
END_FUNC direntry_kind

;; ============================================================================
;; The methods.  Each is a builtin bound to the entry, so args[0] is self.
;; ============================================================================

;; direntry_m_is_dir(rdi = args, rsi = nargs) -> rax = Value, True or False
DEF_FUNC direntry_m_is_dir, 8            ; + 1 push = 16, 16-aligned
    push rbx
    mov rbx, [rdi]
    call posixdir_follow_arg
    mov rdi, rbx
    mov esi, eax
    mov edx, S_IFDIR
    call direntry_kind
    RET_BOOL_RAX
    pop rbx
    leave
    ret
END_FUNC direntry_m_is_dir

;; direntry_m_is_file(rdi = args, rsi = nargs) -> Value (True / False)
DEF_FUNC direntry_m_is_file, 8            ; + 1 push = 16, 16-aligned
    push rbx
    mov rbx, [rdi]
    call posixdir_follow_arg
    mov rdi, rbx
    mov esi, eax
    mov edx, S_IFREG
    call direntry_kind
    RET_BOOL_RAX
    pop rbx
    leave
    ret
END_FUNC direntry_m_is_file

;; direntry_m_is_symlink(rdi = args, rsi = nargs) -> Value (True / False)
DEF_FUNC direntry_m_is_symlink, 8            ; + 1 push = 16, 16-aligned
    push rbx
    mov rbx, [rdi]
    mov rdi, rbx
    xor esi, esi                    ; is_symlink() never follows
    mov edx, S_IFLNK
    call direntry_kind
    RET_BOOL_RAX
    pop rbx
    leave
    ret
END_FUNC direntry_m_is_symlink

;; direntry_m_is_junction(rdi = args, rsi = nargs) -> rax = Value, always False
;; A junction is an NTFS reparse point.  CPython gives DirEntry the method on
;; every platform and answers False off Windows, and os.walk calls it beside
;; is_dir() on every entry it sees.
DEF_FUNC direntry_m_is_junction
    lea rax, [rel bool_false]
    inc qword [rax + PyObject.ob_refcnt]
    leave
    ret
END_FUNC direntry_m_is_junction

;; direntry_m_inode(rdi = args, rsi = nargs) -> Value (int)
DEF_FUNC direntry_m_inode
    mov rdi, [rdi]
    mov rdi, [rdi + PyDirEntryObject.de_ino]
    call int_from_i64
    V_PACK rax, rdx
    leave
    ret
END_FUNC direntry_m_inode

;; direntry_m_fspath(rdi = args, rsi = nargs) -> Value (the path str)
DEF_FUNC direntry_m_fspath
    mov rdi, [rdi]
    mov rax, [rdi + PyDirEntryObject.de_path]
    inc qword [rax + PyObject.ob_refcnt]
    leave
    ret
END_FUNC direntry_m_fspath

;; direntry_m_stat(rdi = args, rsi = nargs) -> Value (os.stat_result)
;; Raises, as os.stat does, when the path cannot be stat'd -- which is what a
;; dangling symlink is, and what tells it apart from is_file()'s False.
DMS_SELF  equ 8
DMS_BUF   equ 16 + StatBuf_size
DMS_FRAME equ 16 + StatBuf_size
DEF_FUNC direntry_m_stat, DMS_FRAME
    mov rax, [rdi]                  ; self -- rdi is still the argument array,
    mov [rbp - DMS_SELF], rax       ; which is what reads the keyword below
    call posixdir_follow_arg
    mov rdi, [rbp - DMS_SELF]
    mov esi, eax
    lea rdx, [rbp - DMS_BUF]
    call direntry_statbuf
    test eax, eax
    jnz .dms_err
    lea rdi, [rbp - DMS_BUF]
    call posix_stat_result
    V_PACK rax, rdx
    leave
    ret
.dms_err:
    mov rdi, rax
    mov rsi, [rbp - DMS_SELF]
    mov rsi, [rsi + PyDirEntryObject.de_path]
    call raise_oserror              ; does not return
END_FUNC direntry_m_stat

;; ============================================================================
;; direntry_getattr(rdi = self, rsi = name str) -> rax = Value, or 0
;; ============================================================================

DEF_FUNC direntry_getattr, 16           ; + 2 pushes = 32, 16-aligned
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi

    lea rdi, [r12 + PyStrObject.data]
    lea rsi, [rel de_n_name]
    call ap_strcmp
    test eax, eax
    jnz .dga_try_path
    mov rax, [rbx + PyDirEntryObject.de_name]
    inc qword [rax + PyObject.ob_refcnt]
    jmp .dga_out

.dga_try_path:
    lea rdi, [r12 + PyStrObject.data]
    lea rsi, [rel de_n_path]
    call ap_strcmp
    test eax, eax
    jnz .dga_methods
    mov rax, [rbx + PyDirEntryObject.de_path]
    inc qword [rax + PyObject.ob_refcnt]
    jmp .dga_out

.dga_methods:
    ; Nothing of ours: let the generic path answer, so __class__ and the rest
    ; still work and a genuinely missing name gets the ordinary message.
    xor eax, eax
    jmp .dga_out

.dga_out:
    pop r12
    pop rbx
    leave
    ret
END_FUNC direntry_getattr

;; ============================================================================
;; direntry_new_refused(rdi = type, rsi = args, rdx = nargs) -> does not return
;; A DirEntry only ever comes from scandir(), as CPython's does.
;; ============================================================================
DEF_FUNC direntry_new_refused
    RAISE exc_TypeError_type, "cannot create 'posix.DirEntry' instances"
END_FUNC direntry_new_refused

;; ============================================================================
;; scandir_iter_dealloc(rdi = self) -> void
;; ============================================================================
DEF_FUNC scandir_iter_dealloc, 8            ; + 1 push = 16, 16-aligned
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + PyScandirIterObject.sd_list]
    test rdi, rdi
    jz .sid_no_list
    mov qword [rbx + PyScandirIterObject.sd_list], 0
    call obj_decref
.sid_no_list:
    mov rdi, rbx
    call ap_free
    pop rbx
    leave
    ret
END_FUNC scandir_iter_dealloc

;; ============================================================================
;; scandir_iter_next(rdi = self) -> rax = the next DirEntry, or 0 when done
;; ============================================================================
DEF_FUNC_BARE scandir_iter_next
    mov rax, [rdi + PyScandirIterObject.sd_list]
    test rax, rax
    jz .sin_done                    ; closed, or already exhausted
    mov rcx, [rdi + PyScandirIterObject.sd_index]
    cmp rcx, [rax + PyListObject.ob_size]
    jge .sin_done
    mov rdx, [rax + PyListObject.ob_item]
    mov rax, [rdx + rcx*8]
    inc qword [rax + PyObject.ob_refcnt]
    inc qword [rdi + PyScandirIterObject.sd_index]
    ret
.sin_done:
    RET_NULL
    ret
END_FUNC scandir_iter_next

;; scandir_iter_m_close(rdi = args, rsi = nargs) -> Value (None)
;; Drops the entries.  Closing twice, and closing an exhausted iterator, are
;; both fine -- shutil and pathlib do both.
DEF_FUNC scandir_iter_m_close, 8            ; + 1 push = 16, 16-aligned
    push rbx
    mov rbx, [rdi]
    mov rdi, [rbx + PyScandirIterObject.sd_list]
    test rdi, rdi
    jz .sic_out
    mov qword [rbx + PyScandirIterObject.sd_list], 0
    call obj_decref
.sic_out:
    lea rax, [rel none_singleton]
    inc qword [rax + PyObject.ob_refcnt]
    pop rbx
    leave
    ret
END_FUNC scandir_iter_m_close

;; scandir_iter_m_enter(rdi = args, rsi = nargs) -> Value (self)
DEF_FUNC scandir_iter_m_enter
    mov rax, [rdi]
    inc qword [rax + PyObject.ob_refcnt]
    leave
    ret
END_FUNC scandir_iter_m_enter

;; scandir_iter_m_exit(rdi = args, rsi = nargs) -> Value (None)
DEF_FUNC scandir_iter_m_exit, 8            ; + 1 push = 16, 16-aligned
    push rbx
    mov rbx, rdi
    mov esi, 1
    call scandir_iter_m_close
    pop rbx
    leave
    ret
END_FUNC scandir_iter_m_exit

;; ============================================================================
;; scandir_iter_getattr(rdi = self, rsi = name str) -> rax = Value, or 0
;; ============================================================================

DEF_FUNC scandir_iter_getattr, 16       ; + 2 pushes = 32, 16-aligned
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi

    xor eax, eax
    jmp .sga_out
.sga_out:
    pop r12
    pop rbx
    leave
    ret
END_FUNC scandir_iter_getattr

;; ============================================================================
;; posix.scandir(path='.') -> an iterator of DirEntry
;;
;; The getdents64 loop is listdir's, with the entry's d_type and d_ino kept
;; instead of thrown away, and the path built once per entry from a prefix
;; computed once.  "." and ".." are filtered, as they are there.
;; ============================================================================
PSD_BUFSZ equ 32768

PSD_PATH   equ 8            ; the argument, for the error message
PSD_FD     equ 16
PSD_LIST   equ 24
PSD_BUF    equ 32
PSD_N      equ 40           ; bytes getdents64 wrote this round
PSD_OFF    equ 48           ; the cursor into the buffer
PSD_OWNED  equ 56           ; what posix_path_arg asked us to release
PSD_ERR    equ 64           ; an errno held across the cleanup before it raises
PSD_PREFIX equ 72           ; the directory, with a separator, as a str
PSD_ITER   equ 80
; Whether the argument was a BYTES.  CPython gives a bytes path bytes .name
; and .path, and posix_path_arg used to discard the distinction, so both were
; str -- which os.walk(b'.') and the bytes half of glob then propagate.
PSD_ISBYTES equ 88
PSD_FRAME  equ 96           ; + 2 pushes = 112, 16-aligned

DEF_FUNC posix_scandir, PSD_FRAME
    push rbx
    push r12
    mov qword [rbp - PSD_BUF], 0
    mov qword [rbp - PSD_LIST], 0
    mov qword [rbp - PSD_PREFIX], 0
    mov qword [rbp - PSD_ITER], 0
    mov qword [rbp - PSD_FD], -1
    mov qword [rbp - PSD_OWNED], 0

    ; The default is ".", as os.scandir()'s is.
    test rsi, rsi
    jz .psd_dot
    mov rdi, [rdi]
    IS_NONE rdi, rax
    je .psd_dot
    mov [rbp - PSD_PATH], rdi
    CSTRING rsi, "scandir: path"
    mov edx, POSIX_PATH_KIND_PLAIN
    call posix_path_arg
    test rax, rax
    jz .psd_fail
    mov rbx, rax
    mov [rbp - PSD_OWNED], rdx
    mov [rbp - PSD_ISBYTES], rcx    ; a bytes path gets bytes names and paths
    jmp .psd_prefix
.psd_dot:
    mov qword [rbp - PSD_PATH], 0
    mov qword [rbp - PSD_ISBYTES], 0
    CSTRING rbx, "."

.psd_prefix:
    ; .path is the argument joined to the name, so build "<arg>/" once.  An
    ; argument that already ends in a separator does not get a second one, and
    ; an empty one gets none at all -- which is what os.path.join does and
    ; what makes scandir('') behave like scandir('.') with bare names.
    ; ob_size is the length in bytes for both kinds, and .data is at a
    ; different offset for each -- so the separator test branches too.
    mov rdi, rbx
    mov esi, [rbp - PSD_ISBYTES]
    call posix_name_object
    test rax, rax
    jz .psd_fail
    mov [rbp - PSD_PREFIX], rax
    mov rcx, [rax + PyStrObject.ob_size]    ; ob_size is +16 for both
    test rcx, rcx
    jz .psd_open                    ; empty: no separator
    cmp qword [rbp - PSD_ISBYTES], 0
    jne .psd_prefix_sep_bytes
    cmp byte [rax + PyStrObject.data + rcx - 1], '/'
    je .psd_open
    jmp .psd_prefix_add_sep
.psd_prefix_sep_bytes:
    cmp byte [rax + PyBytesObject.data + rcx - 1], '/'
    je .psd_open
.psd_prefix_add_sep:
    push rax
    CSTRING rdi, "/"
    mov esi, [rbp - PSD_ISBYTES]
    call posix_name_object
    test rax, rax
    jz .psd_fail_pop
    mov rsi, rax
    mov rdi, [rbp - PSD_PREFIX]
    push rsi
    call psd_join
    pop rsi
    mov r12, rax
    mov rdi, rsi
    call obj_decref                 ; the separator
    pop rdi
    call obj_decref                 ; the old prefix
    mov [rbp - PSD_PREFIX], r12
    test r12, r12
    jz .psd_fail

.psd_open:
    mov rdi, rbx
    mov esi, O_RDONLY | O_DIRECTORY | O_CLOEXEC
    xor edx, edx
    call sys_open
    cmp rax, -4095
    jb .psd_opened
    neg rax
    mov [rbp - PSD_ERR], rax
    PD_PATH_DONE [rbp - PSD_OWNED]
    mov rdi, [rbp - PSD_PREFIX]
    test rdi, rdi
    jz .psd_open_raise
    mov qword [rbp - PSD_PREFIX], 0
    call obj_decref
.psd_open_raise:
    mov rdi, [rbp - PSD_ERR]
    mov rsi, [rbp - PSD_PATH]
    call raise_oserror              ; does not return
.psd_opened:
    mov [rbp - PSD_FD], rax

    mov edi, PSD_BUFSZ
    call ap_malloc
    test rax, rax
    jz .psd_fail
    mov [rbp - PSD_BUF], rax

    xor edi, edi
    call list_new
    test rax, rax
    jz .psd_fail
    mov [rbp - PSD_LIST], rax

.psd_refill:
    mov rdi, [rbp - PSD_FD]
    mov rsi, [rbp - PSD_BUF]
    mov edx, PSD_BUFSZ
    call sys_getdents64
    ; Not POSIX_CHECK: by here the descriptor is open and the list is half
    ; built, and a raise abandons the C stack without running any cleanup.
    cmp rax, -4095
    jb .psd_read_ok
    neg rax
    mov [rbp - PSD_ERR], rax
    call posixdir_cleanup
    mov rdi, [rbp - PSD_ERR]
    mov rsi, [rbp - PSD_PATH]
    call raise_oserror              ; does not return
.psd_read_ok:
    test rax, rax
    jz .psd_done
    mov [rbp - PSD_N], rax
    mov qword [rbp - PSD_OFF], 0

.psd_record:
    mov rax, [rbp - PSD_OFF]
    cmp rax, [rbp - PSD_N]
    jge .psd_refill
    mov rbx, [rbp - PSD_BUF]
    add rbx, rax                    ; rbx = this record
    ; The stride, read as the 16-bit field it is: a 64-bit read ORs in d_type
    ; and five bytes of the name, and the stride walks off the end.
    movzx r12d, word [rbx + LinuxDirent64.d_reclen]

    lea rdi, [rbx + LinuxDirent64.d_name]
    cmp byte [rdi], '.'
    jne .psd_keep
    cmp byte [rdi + 1], 0
    je .psd_next
    cmp byte [rdi + 1], '.'
    jne .psd_keep
    cmp byte [rdi + 2], 0
    je .psd_next

.psd_keep:
    mov esi, [rbp - PSD_ISBYTES]
    call posix_name_object
    test rax, rax
    jz .psd_fail
    push rax                        ; the name
    mov rdi, [rbp - PSD_PREFIX]
    mov rsi, rax
    call psd_join
    test rax, rax
    jz .psd_fail_pop
    push rax                        ; the path
    mov rdi, [rsp + 8]              ; name
    mov rsi, rax                    ; path
    movzx edx, byte [rbx + LinuxDirent64.d_type]
    mov rcx, [rbx + LinuxDirent64.d_ino]
    call direntry_new
    mov rcx, rax
    pop rdi
    push rcx
    call obj_decref                 ; the path; direntry_new took its own
    pop rcx
    pop rdi
    push rcx
    call obj_decref                 ; the name, likewise
    pop rcx
    test rcx, rcx
    jz .psd_fail
    mov rdi, [rbp - PSD_LIST]
    mov rsi, rcx
    push rcx
    call list_append
    pop rdi
    call obj_decref                 ; the list took its own

.psd_next:
    mov rax, [rbp - PSD_OFF]
    add rax, r12
    mov [rbp - PSD_OFF], rax
    jmp .psd_record

.psd_done:
    mov rdi, [rbp - PSD_FD]
    call sys_close
    mov qword [rbp - PSD_FD], -1
    mov rdi, [rbp - PSD_BUF]
    call ap_free
    mov qword [rbp - PSD_BUF], 0
    PD_PATH_DONE [rbp - PSD_OWNED]
    mov rdi, [rbp - PSD_PREFIX]
    test rdi, rdi
    jz .psd_wrap
    mov qword [rbp - PSD_PREFIX], 0
    call obj_decref

.psd_wrap:
    mov edi, PyScandirIterObject_size
    call ap_malloc
    test rax, rax
    jz .psd_fail
    mov qword [rax + PyScandirIterObject.ob_refcnt], 1
    lea rcx, [rel scandir_iter_type]
    mov [rax + PyScandirIterObject.ob_type], rcx
    mov rcx, [rbp - PSD_LIST]
    mov [rax + PyScandirIterObject.sd_list], rcx    ; takes over the reference
    mov qword [rbp - PSD_LIST], 0
    mov qword [rax + PyScandirIterObject.sd_index], 0
    pop r12
    pop rbx
    leave
    ret

.psd_fail_pop:
    pop rdi
    test rdi, rdi
    jz .psd_fail
    call obj_decref
.psd_fail:
    call posixdir_cleanup
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
END_FUNC posix_scandir

;; ============================================================================
;; posixdir_cleanup() -> void
;;
;; Everything posix_scandir may be holding, released in one place: it is
;; reached both from the error paths and from the arm that has to close and
;; free BEFORE it raises, because a raise never comes back.  It reads the
;; caller's frame through rbp, which is why it carves none of its own.
;; ============================================================================
DEF_FUNC_LOCAL posixdir_cleanup, 8      ; + 1 push = 16, 16-aligned
    push rbx
    mov rbx, rbp                ; this frame's rbp
    mov rbx, [rbx]              ; the caller's

    PD_PATH_DONE [rbx - PSD_OWNED]
    mov rdi, [rbx - PSD_FD]
    test rdi, rdi
    jl .pdc_buf
    call sys_close
    mov qword [rbx - PSD_FD], -1
.pdc_buf:
    mov rdi, [rbx - PSD_BUF]
    test rdi, rdi
    jz .pdc_list
    mov qword [rbx - PSD_BUF], 0
    call ap_free
.pdc_list:
    mov rdi, [rbx - PSD_LIST]
    test rdi, rdi
    jz .pdc_prefix
    mov qword [rbx - PSD_LIST], 0
    call obj_decref
.pdc_prefix:
    mov rdi, [rbx - PSD_PREFIX]
    test rdi, rdi
    jz .pdc_out
    mov qword [rbx - PSD_PREFIX], 0
    call obj_decref
.pdc_out:
    pop rbx
    leave
    ret
END_FUNC posixdir_cleanup

%macro PD_ADD_FN 2              ; %1 = the name symbol, %2 = the implementation
    mov rdi, rbx
    lea rsi, [rel %1]
    lea rdx, [rel %2]
    call dict_add_builtin_func
%endmacro

;; ============================================================================
;; posixdir_register(rdi = the posix module dict) -> void
;; Puts scandir and DirEntry in it.
;; ============================================================================
PDR_ENT   equ 8
PDR_KEY   equ 16
PDR_FRAME equ 32            ; + 1 push = 40 ... padded below
DEF_FUNC posixdir_register, PDR_FRAME
    push r12
    push rbx                    ; 32 + 16 = 48, so the calls below are aligned
    mov r12, rdi

    MODULE_ADD_FUNC posix_scandir, pd_n_scandir

    ; The methods go in each type's tp_dict, not just behind tp_getattr.  The
    ; stdlib asks by name -- os.fspath looks up __fspath__ on the TYPE, and a
    ; slot with no matching entry answers that question wrong.
    call dict_new
    test rax, rax
    jz .pdr_no_dict
    mov rbx, rax
    lea rcx, [rel direntry_type]
    mov [rcx + PyTypeObject.tp_dict], rax
    PD_ADD_FN de_n_is_dir,     direntry_m_is_dir
    PD_ADD_FN de_n_is_file,    direntry_m_is_file
    PD_ADD_FN de_n_is_symlink, direntry_m_is_symlink
    PD_ADD_FN de_n_stat,       direntry_m_stat
    PD_ADD_FN de_n_inode,      direntry_m_inode
    PD_ADD_FN de_n_is_junction, direntry_m_is_junction
    PD_ADD_FN de_n_fspath,     direntry_m_fspath

    call dict_new
    test rax, rax
    jz .pdr_no_dict
    mov rbx, rax
    lea rcx, [rel scandir_iter_type]
    mov [rcx + PyTypeObject.tp_dict], rax
    PD_ADD_FN sd_n_close, scandir_iter_m_close
    PD_ADD_FN sd_n_enter, scandir_iter_m_enter
    PD_ADD_FN sd_n_exit,  scandir_iter_m_exit
    ; ...and the two the iterator protocol is asked for BY NAME.  init_iter's
    ; table leaves this type out because it already has a tp_dict, and its
    ; header says the two entries are added "in the block that built it" --
    ; which is this one, and they were not: hasattr(os.scandir('.'),
    ; '__next__') was False and both thunks were dead code.
    extern scandir_iter_dunder_next
    extern scandir_iter_dunder_iter
    PD_ADD_FN sd_n_next, scandir_iter_dunder_next
    PD_ADD_FN sd_n_iter, scandir_iter_dunder_iter

    ; Stamp both, as every type built in src/methods/init.asm is stamped.
    ; Without it a method here is indistinguishable from a module-level
    ; function -- same type, same func_kind, no owner -- so nothing can tell
    ; that DirEntry.is_dir is a descriptor and os.unlink is not.  It also
    ; installs the receiver check and gives the repr a method's wording.
    extern type_stamp_methods
    lea rdi, [rel direntry_type]
    call type_stamp_methods
    lea rdi, [rel scandir_iter_type]
    call type_stamp_methods
.pdr_no_dict:

    lea rax, [rel direntry_type]
    inc qword [rax + PyObject.ob_refcnt]
    mov [rbp - PDR_ENT], rax
    lea rdi, [rel pd_n_DirEntry]
    call str_from_cstr_heap
    mov [rbp - PDR_KEY], rax
    mov rdi, r12
    mov rsi, rax
    mov rdx, [rbp - PDR_ENT]
    call dict_set
    mov rdi, [rbp - PDR_ENT]
    call obj_decref
    mov rdi, [rbp - PDR_KEY]
    call obj_decref

    pop rbx
    pop r12
    leave
    ret
END_FUNC posixdir_register

section .rodata

de_name_str:  db "posix.DirEntry", 0
sd_name_str:  db "posix.ScandirIterator", 0

de_n_name:       db "name", 0
de_n_path:       db "path", 0
de_n_is_dir:     db "is_dir", 0
de_n_is_file:    db "is_file", 0
de_n_is_symlink: db "is_symlink", 0
de_n_stat:       db "stat", 0
de_n_inode:      db "inode", 0
de_n_is_junction: db "is_junction", 0
de_n_fspath:     db "__fspath__", 0

sd_n_close:  db "close", 0
sd_n_next:   db "__next__", 0
sd_n_iter:   db "__iter__", 0
sd_n_enter:  db "__enter__", 0
sd_n_exit:   db "__exit__", 0

pd_n_scandir:  db "scandir", 0
pd_n_DirEntry: db "DirEntry", 0

section .data

extern type_type
extern iter_self

align 8
direntry_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq de_name_str              ; tp_name
    dq PyDirEntryObject_size    ; tp_basicsize
    dq direntry_dealloc         ; tp_dealloc
    dq direntry_repr            ; tp_repr
    dq direntry_repr            ; tp_str
    dq 0                        ; tp_hash
    dq 0                        ; tp_call
    dq direntry_getattr         ; tp_getattr
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq 0                        ; tp_iter
    dq 0                        ; tp_iternext
    dq 0                        ; tp_init
    dq direntry_new_refused     ; tp_new
    dq 0                        ; tp_as_number
    dq 0                        ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq 0                        ; tp_flags
    dq 0                        ; tp_bases
    dq 0                        ; tp_traverse
    dq 0                        ; tp_clear
    dq 0                        ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer

align 8
scandir_iter_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq sd_name_str              ; tp_name
    dq PyScandirIterObject_size ; tp_basicsize
    dq scandir_iter_dealloc     ; tp_dealloc
    dq 0                        ; tp_repr
    dq 0                        ; tp_str
    dq 0                        ; tp_hash
    dq 0                        ; tp_call
    dq scandir_iter_getattr     ; tp_getattr
    dq 0                        ; tp_setattr
    dq 0                        ; tp_richcompare
    dq iter_self                ; tp_iter
    dq scandir_iter_next        ; tp_iternext
    dq 0                        ; tp_init
    dq 0                        ; tp_new
    dq 0                        ; tp_as_number
    dq 0                        ; tp_as_sequence
    dq 0                        ; tp_as_mapping
    dq 0                        ; tp_base
    dq 0                        ; tp_dict
    dq 0                        ; tp_mro
    dq 0                        ; tp_flags
    dq 0                        ; tp_bases
    dq 0                        ; tp_traverse
    dq 0                        ; tp_clear
    dq 0                        ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer
