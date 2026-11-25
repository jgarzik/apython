; include/posixpath.inc - the private ABI between posix.asm, posixpath.asm and
; the other callers of posix_path_arg
;
; posixpath.asm turns one argument into a NUL-terminated C string; posix.asm,
; posixdir.asm and modules/io.asm consume what it hands back.  The release
; macro and the accepted-kind constants are what the two halves have to agree
; on, so they live here rather than in either of them -- the same arrangement
; sre.inc, eventloop.inc and listsort.inc already use.

%ifndef POSIXPATH_INC
%define POSIXPATH_INC

; Which kinds a caller takes, for the refusal's wording.  CPython lists the
; kinds THAT function accepts, and they differ.
POSIX_PATH_KIND_PLAIN   equ 0
POSIX_PATH_KIND_FD      equ 1
POSIX_PATH_KIND_FD_NONE equ 2
; _io words the same refusal its own way -- "expected str, bytes or
; os.PathLike object, not NoneType" -- and open() has to say what CPython's
; open() says, so the whole sentence comes from there rather than the
; "<who> should be ..." shape the posix entry points share.
POSIX_PATH_KIND_IO      equ 3

;; ============================================================================
;; posix_path_arg(rdi = Value) -> rax = const char *, rdx = an object the
;;   caller must release, or 0
;;
;; str, bytes, and anything with __fspath__.  Every PyStrObject and
;; PyBytesObject here is NUL-terminated, so for those two the pointer is the
;; caller's own path with no copy and rdx comes back 0.
;;
;; __fspath__ is the case that allocates: its result is a new str or bytes,
;; the returned pointer is into it, and it stays alive exactly as long as the
;; caller holds it.  rdx is that object.  Every caller used to ignore it --
;; the contract said "owned" in a flag nobody read -- so every PathLike
;; argument leaked its resolved path.
;;
;; POSIX_PATH_DONE is the release, and it belongs immediately after the
;; syscall: by then the kernel has copied the path out.  A caller whose error
;; names the path uses POSIX_PATH_CHECK_RET instead, which releases it on both
;; arms.
;;
;; An embedded NUL is refused: the syscall would silently see a shorter path,
;; and CPython raises ValueError for exactly this.
;;
;; EVERY refusal answers rax = 0 with the exception already pending, and none
;; of them raises: not a bad type, not an embedded NUL, not a __fspath__ that
;; raised, not a __fspath__ that handed back something that is not a path.
;; Its docblock carries `Fails: 0`, so every caller writes `ERR_NULL .fail`,
;; and .fail still has to clean up and return 0 itself.
;;
;; It returns rather than raising because of the callers that resolve TWO
;; paths.  rename, symlink, link and putenv convert the first, hold what it
;; owns, and then convert the second; a raise from the second abandons the C
;; stack, so the cleanup they have ready never runs and the first path's
;; resolved string leaks.  This used to raise, the line here used to claim it
;; did not, and all twenty-four call sites had been written to the claim --
;; their `jz` arms were dead code, and the four two-path ones leaked about 64
;; bytes on every refusal of a second argument.
;; ============================================================================
%macro POSIX_PATH_DONE 1        ; %1 = a frame slot holding what rdx returned
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

;; The check and the release, in the order they have to happen: the errno
;; check names the RESOLVED path, so the release cannot come first -- CPython
;; reports "No such file or directory: '/tmp/x'", not the PathLike object that
;; produced it.  The OSError is recorded through set_oserror_owned, which
;; releases the resolved path as it does so, and control goes to the caller's
;; error exit.  On success it falls through with the path released.
%macro POSIX_PATH_CHECK_RET 4   ; %1 = result, %2 = the original Value,
                                ; %3 = the slot holding the resolved path,
                                ; %4 = the error exit
    cmp %1, -4095
    jb %%ok
    mov rdi, %1
    neg rdi
    mov rsi, %2
    mov rdx, %3
    call set_oserror_owned
    mov qword %3, 0             ; released there; the exit must not again
    jmp %4
%%ok:
    POSIX_PATH_DONE %3
%endmacro

%endif ; POSIXPATH_INC
