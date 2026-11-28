; import_find.asm - where the assembly finder looks for a module
;
; The path search behind import_find_and_load_asm (src/import.asm), which is
; what loads a module before CPython's importlib is up, and builtins after:
; which file under a sys.path entry answers a name -- a package directory, a
; cached .pyc under either tag, a sourceless .pyc, the source itself -- when a
; .pyc is stale against its source, the PEP 420 portions a directory with no
; __init__ contributes and the namespace module made from them, and the
; absolute form of a path given on the command line.
;
; Split off when import.asm reached the 100k cap, along the line it already
; had: everything above decides WHAT to import, this decides WHERE it is.


%include "macros.inc"
%include "object.inc"

extern dict_get
extern dict_set
extern dict_get_str
extern dict_set_str
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
extern exc_set_import
extern set_exception
extern str_from_cstr_heap
extern str_intern_cstr
extern dict_new
extern list_new
extern list_append
extern type_type
extern module_new
extern fatal_error
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

; sys module globals
extern sys_modules_dict
extern sys_path_list
extern sys_module_init

; builtins
extern builtins_dict_global
extern exc_ImportError_type
extern exc_ModuleNotFoundError_type
extern str_concat

; What src/import.asm keeps and this reads
extern ts_get_path_scratch
extern im_dunder_name
extern im_dunder_file
extern im_dunder_loader
extern im_dunder_spec
extern im_dunder_package
extern im_dunder_path
extern im_dunder_builtins

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

section .text

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

    push rax                    ; save first byte offset of <name>
    push rcx                    ; save name length
    call ts_get_path_scratch
    lea r13, [rax + TS_PATH_ISP]
    mov rdi, r13
    mov rsi, rbx
    mov rdx, r14
    call ap_memcpy              ; <dir>, without the trailing slash
    pop rcx
    pop rax
    lea rdi, [r13 + r14]
    mov byte [rdi], '/'
    inc rdi
    lea rsi, [rbx + rax]
    mov rdx, rcx
    push rcx
    call ap_memcpy
    pop rcx
    lea rdi, [r13 + r14]
    add rdi, rcx
    inc rdi
    mov dword [rdi], `.py\0`
    mov rax, r13
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

; Frame layout for import_search_dirs
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
    call ts_get_path_scratch
    lea r12, [rax + TS_PATH_IMPORT]     ; r12 = dest buf

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

    call ts_get_path_scratch
    lea r12, [rax + TS_PATH_IMPORT]     ; dest buf

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
    mov rax, [gs:ThreadState.ts_import_ns_portions]
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
    mov rdi, [gs:ThreadState.ts_import_ns_portions]
    test rdi, rdi
    jz .inpc_done
    mov qword [gs:ThreadState.ts_import_ns_portions], 0
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

    mov rax, [gs:ThreadState.ts_import_ns_portions]
    test rax, rax
    jnz .inpa_have_list
    xor edi, edi
    call list_new
    test rax, rax
    jz .inpa_done
    mov [gs:ThreadState.ts_import_ns_portions], rax
.inpa_have_list:
    mov rdi, [rbp - INPA_PATH]
    mov rsi, [rbp - INPA_LEN]
    call str_new_heap
    test rax, rax
    jz .inpa_done
    mov [rbp - INPA_STR], rax
    mov rdi, [gs:ThreadState.ts_import_ns_portions]
    mov rsi, rax
    call list_append          ; err: a list built here is not being sorted
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
global import_make_namespace
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
    mov rsi, [gs:ThreadState.ts_import_ns_portions]
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
    ERR_M1 .imn_fail_mod

    ; The module owns the dict now; release what dict_new gave us.
    mov rdi, [rbp - IMN_DICT]
    call obj_decref
    mov rax, [rbp - IMN_MOD]
    leave
    ret

.imn_fail_mod:                  ; sys.modules refused it
    mov rdi, [rbp - IMN_MOD]
    call obj_decref
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
    call dict_set_str
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

    call ts_get_path_scratch
    lea rdi, [rax + TS_PATH_IAP]
    mov esi, IAP_BUFSZ - 1
    call sys_getcwd
    test rax, rax
    js .iap_asis
    call ts_get_path_scratch
    lea rdi, [rax + TS_PATH_IAP]
    call ap_strlen
    mov rbx, rax
    cmp rbx, 1
    jbe .iap_have_cwd                   ; "/" already ends in a slash
    call ts_get_path_scratch
    lea rdi, [rax + TS_PATH_IAP]
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
    mov rdx, rax
    call ts_get_path_scratch
    lea rdi, [rax + TS_PATH_IAP]
    add rdi, rbx
    add rbx, rdx                        ; ap_memcpy answers the DEST, not the
                                        ; length, so the sum is taken first
    call ap_memcpy
    call ts_get_path_scratch
    lea rdi, [rax + TS_PATH_IAP]
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
;; Data
;; ============================================================================
section .rodata

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

ISP_BUFSZ equ 4096
IAP_BUFSZ equ 4096
