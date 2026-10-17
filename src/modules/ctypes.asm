; ctypes.asm - the `_ctypescore` module: dlopen, raw memory and libffi.
;
; The same split src/modules/zlib.asm's header states as a contract.  What is
; genuinely C lives here -- the dynamic loader, reading and writing memory at
; an address, and the call through libffi -- and everything a Python program
; sees is lib/_ctypes.py: the metatypes, _SimpleCData, Structure, Union,
; Array, _Pointer and CFuncPtr, the layout rules, the conversions.  So every
; function here takes a fixed number of positional arguments and answers with
; an int, a bytes, a str or None.
;
; Unlike the other shims, an argument here IS a raw address.  That is the
; whole of ctypes: a program that can call `memmove` can already write
; anywhere, and CPython's _ctypes dereferences whatever integer it is handed
; in exactly the same way.  So nothing here is a handle table.
;
; The ffi_cif, the ffi_type structs and the argument-pointer array are built
; by lib/_ctypes.py in memory it owns (a bytearray's buffer, whose address
; `addr` answers), so the assembly never needs to know a ctypes type.  The
; call itself is libffi's.
;
; A callback is one trampoline, cx_tramp, for every CFUNCTYPE.  libffi hands
; it the return slot and the argument-pointer array, and it hands both on to
; the Python callable the closure was made for, as two ints; the Python side
; knows the signature and does the conversions.  Calling Python from here is
; what src/modules/pyexpat_cb.asm's header explains: a called Python function
; that raises returns normally with current_exception set, so the C frames
; between here and ffi_call are left intact.  The Python side catches
; everything itself and reports it as unraisable, as CPython does; the clear
; below is only a backstop.
;
;   **NEVER `RAISE` FROM cx_tramp.**  It would discard the C frames of
;   whatever library is calling back.

%include "macros.inc"
%include "object.inc"

ASM_INIT

extern none_singleton
extern dict_new
extern module_new
extern str_from_cstr_heap
extern obj_decref
extern obj_dealloc
extern int_from_i64
extern builtin_func_new
extern dict_set
extern bytes_from_data
extern bytes_type
extern bytearray_type
extern memoryview_type
extern ap_memcpy
extern obj_as_index
extern obj_call_n
extern current_exception
extern kw_names_pending
extern raise_exception
extern raise_type_error_with_name
extern exc_TypeError_type

extern dlopen
extern dlsym
extern dlclose
extern dlerror
extern strlen
extern __errno_location
extern ffi_prep_cif
extern ffi_prep_cif_var
extern ffi_call
extern ffi_closure_alloc
extern ffi_closure_free
extern ffi_prep_closure_loc

CX_CLOSURE_SIZE equ 64          ; sizeof(ffi_closure) is 56 on x86-64

section .bss
; The ctypes-private errno, which a function made with use_errno=True swaps
; with the real one around the call -- CPython keeps it per thread, and there
; is one thread.
cx_errno: resq 1

section .text

;; ============================================================================
;; cx_arg_i64(rdi = args, rsi = index) -> rax = the int
;;
;; Does not return when the argument is not an index.
;; ============================================================================
DEF_FUNC_BARE cx_arg_i64
    mov rdi, [rdi + rsi*8]
    V_UNPACK rdi, rdx
    jmp obj_as_index
END_FUNC cx_arg_i64

;; ============================================================================
;; cx_buffer(rdi = a Value) -> rax = data pointer, rdx = length, ecx = 1;
;;   ecx = 0 when it is not a bytes, a bytearray or a contiguous memoryview
;;
;; lib/_ctypes.py wraps anything else that has a buffer in a memoryview first,
;; so these three are all this needs to know.  An empty bytearray may have no
;; buffer at all; it answers 0 too, which the caller reads as "no address".
;; ============================================================================
DEF_FUNC_BARE cx_buffer
    V_TEST_PTR rdi, rax
    ja .cb_no
    test rdi, rdi
    jz .cb_no
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel bytes_type]
    cmp rax, rcx
    je .cb_bytes
    lea rcx, [rel bytearray_type]
    cmp rax, rcx
    je .cb_bytearray
    lea rcx, [rel memoryview_type]
    cmp rax, rcx
    jne .cb_no
    cmp qword [rdi + PyMemoryViewObject.mv_stride], 1
    jne .cb_no
    mov rax, [rdi + PyMemoryViewObject.mv_buf]
    test rax, rax
    jz .cb_no                   ; released
    mov rdx, [rdi + PyMemoryViewObject.mv_len]
    mov ecx, 1
    ret
.cb_bytearray:
    mov rdx, [rdi + PyByteArrayObject.ob_size]
    mov rax, [rdi + PyByteArrayObject.ob_bytes]
    mov ecx, 1
    ret
.cb_bytes:
    mov rdx, [rdi + PyBytesObject.ob_size]
    lea rax, [rdi + PyBytesObject.data]
    mov ecx, 1
    ret
.cb_no:
    xor eax, eax
    xor edx, edx
    xor ecx, ecx
    ret
END_FUNC cx_buffer

;; ============================================================================
;; cx_ret_int(rdi = int64) -> rax = the int as a Value
;;
;; Called as a function's last act; the caller's own `leave; ret` follows.
;; ============================================================================
DEF_FUNC cx_ret_int
    call int_from_i64
    V_PACK rax, rdx
    leave
    ret
END_FUNC cx_ret_int

;; ============================================================================
;; cx_ret_none() -> rax = None, a new reference
;; ============================================================================
DEF_FUNC_BARE cx_ret_none
    lea rax, [rel none_singleton]
    inc qword [rax + PyObject.ob_refcnt]
    ret
END_FUNC cx_ret_none

;; ============================================================================
;; cx_nargs() -> does not return; the one arity error every function shares
;; ============================================================================
DEF_FUNC_BARE cx_nargs
    RAISE exc_TypeError_type, "_ctypescore: wrong number of arguments"
END_FUNC cx_nargs

;; ============================================================================
;; _ctypescore.dlopen(name, mode) -> int handle, 0 on failure
;;
;; name is a bytes (lib/_ctypes.py fsencodes) or None, which is dlopen(NULL):
;; the program itself and everything it was linked against.
;; ============================================================================
DO_ARGS  equ 8
DO_MODE  equ 16
DO_FRAME equ 16             ; + 0 pushes = 16, 16-aligned
DEF_FUNC cx_dlopen, DO_FRAME
    cmp rsi, 2
    jne cx_nargs
    mov [rbp - DO_ARGS], rdi
    mov esi, 1
    call cx_arg_i64
    mov [rbp - DO_MODE], rax
    mov rax, [rbp - DO_ARGS]
    mov rdi, [rax]
    lea rcx, [rel none_singleton]
    cmp rdi, rcx
    je .do_null
    call cx_buffer
    test ecx, ecx
    jz .do_type
    mov rdi, rax
    jmp .do_go
.do_null:
    xor edi, edi
.do_go:
    mov esi, [rbp - DO_MODE]
    call dlopen wrt ..plt
    mov rdi, rax
    call cx_ret_int
    leave
    ret
.do_type:
    RAISE exc_TypeError_type, "_ctypescore.dlopen: name must be bytes or None"
END_FUNC cx_dlopen

;; ============================================================================
;; _ctypescore.dlsym(handle, name) -> int address, 0 when not found
;; ============================================================================
DS_ARGS  equ 8
DS_H     equ 16
DS_FRAME equ 16             ; + 0 pushes = 16, 16-aligned
DEF_FUNC cx_dlsym, DS_FRAME
    cmp rsi, 2
    jne cx_nargs
    mov [rbp - DS_ARGS], rdi
    xor esi, esi
    call cx_arg_i64
    mov [rbp - DS_H], rax
    mov rax, [rbp - DS_ARGS]
    mov rdi, [rax + 8]
    call cx_buffer
    test ecx, ecx
    jz .ds_type
    mov rsi, rax
    mov rdi, [rbp - DS_H]
    call dlsym wrt ..plt
    mov rdi, rax
    call cx_ret_int
    leave
    ret
.ds_type:
    RAISE exc_TypeError_type, "_ctypescore.dlsym: name must be bytes"
END_FUNC cx_dlsym

;; ============================================================================
;; _ctypescore.dlclose(handle) -> int, dlclose's own answer
;; ============================================================================
DEF_FUNC cx_dlclose
    cmp rsi, 1
    jne cx_nargs
    xor esi, esi
    call cx_arg_i64
    mov rdi, rax
    call dlclose wrt ..plt
    movsxd rdi, eax
    call cx_ret_int
    leave
    ret
END_FUNC cx_dlclose

;; ============================================================================
;; _ctypescore.dlerror() -> str, or None when nothing has failed since the
;;   last call
;; ============================================================================
DEF_FUNC cx_dlerror
    call dlerror wrt ..plt
    test rax, rax
    jz .de_none
    mov rdi, rax
    call str_from_cstr_heap
    leave
    ret
.de_none:
    call cx_ret_none
    leave
    ret
END_FUNC cx_dlerror

;; ============================================================================
;; _ctypescore.addr(obj) -> int, the address of a bytes, bytearray or
;;   memoryview's data
;;
;; What every ctypes instance's own memory hangs off: lib/_ctypes.py owns its
;; buffers as bytearrays, which never move while they are not resized.
;; ============================================================================
AD_OBJ   equ 8
AD_FRAME equ 16             ; + 0 pushes = 16, 16-aligned
DEF_FUNC cx_addr, AD_FRAME
    cmp rsi, 1
    jne cx_nargs
    mov rdi, [rdi]
    mov [rbp - AD_OBJ], rdi
    call cx_buffer
    test ecx, ecx
    jz .ad_type
    mov rdi, rax
    call cx_ret_int
    leave
    ret
.ad_type:
    lea rdi, [rel cx_e_buffer]
    mov rsi, [rbp - AD_OBJ]
    leave
    jmp raise_type_error_with_name
END_FUNC cx_addr

;; ============================================================================
;; _ctypescore.read(address, n) -> bytes, the n bytes there
;; ============================================================================
RD_ARGS  equ 8
RD_ADDR  equ 16
RD_FRAME equ 16             ; + 0 pushes = 16, 16-aligned
DEF_FUNC cx_read, RD_FRAME
    cmp rsi, 2
    jne cx_nargs
    mov [rbp - RD_ARGS], rdi
    xor esi, esi
    call cx_arg_i64
    mov [rbp - RD_ADDR], rax
    mov rdi, [rbp - RD_ARGS]
    mov esi, 1
    call cx_arg_i64
    mov rsi, rax
    test rsi, rsi
    jg .rd_some
    xor esi, esi
.rd_some:
    mov rdi, [rbp - RD_ADDR]
    call bytes_from_data
    leave
    ret
END_FUNC cx_read

;; ============================================================================
;; _ctypescore.write(address, data) -> None; copies all of data there
;; ============================================================================
WR_ARGS  equ 8
WR_ADDR  equ 16
WR_FRAME equ 16             ; + 0 pushes = 16, 16-aligned
DEF_FUNC cx_write, WR_FRAME
    cmp rsi, 2
    jne cx_nargs
    mov [rbp - WR_ARGS], rdi
    xor esi, esi
    call cx_arg_i64
    mov [rbp - WR_ADDR], rax
    mov rax, [rbp - WR_ARGS]
    mov rdi, [rax + 8]
    call cx_buffer
    test ecx, ecx
    jz .wr_type
    test rdx, rdx
    jz .wr_done
    mov rsi, rax
    mov rdi, [rbp - WR_ADDR]
    call ap_memcpy
.wr_done:
    call cx_ret_none
    leave
    ret
.wr_type:
    RAISE exc_TypeError_type, "_ctypescore.write: data must be bytes-like"
END_FUNC cx_write

;; ============================================================================
;; _ctypescore.strlen(address) -> int
;; ============================================================================
DEF_FUNC cx_strlen
    cmp rsi, 1
    jne cx_nargs
    xor esi, esi
    call cx_arg_i64
    mov rdi, rax
    call strlen wrt ..plt
    mov rdi, rax
    call cx_ret_int
    leave
    ret
END_FUNC cx_strlen

;; ============================================================================
;; _ctypescore.wcslen(address) -> int, counting 4-byte wchar_t units
;; ============================================================================
DEF_FUNC cx_wcslen
    cmp rsi, 1
    jne cx_nargs
    xor esi, esi
    call cx_arg_i64
    xor edi, edi
.wl_loop:
    cmp dword [rax + rdi*4], 0
    je .wl_done
    inc rdi
    jmp .wl_loop
.wl_done:
    call cx_ret_int
    leave
    ret
END_FUNC cx_wcslen

; The frame the functions below that take only ints share: their arguments,
; converted, at PC_V.
PC_ARGS  equ 8
PC_V     equ 56                 ; six int64s at [rbp-56 .. rbp-16]
PC_FRAME equ 64                 ; + 0 pushes = 64, 16-aligned

%macro CX_LOAD_INTS 1           ; %1 = how many arguments, into PC_V
    mov [rbp - PC_ARGS], rdi
%assign %%i 0
%rep %1
    mov rdi, [rbp - PC_ARGS]
    mov esi, %%i
    call cx_arg_i64
    mov [rbp - PC_V + %%i*8], rax
%assign %%i %%i+1
%endrep
%endmacro

;; ============================================================================
;; _ctypescore.prep_cif(cif, abi, nargs, rtype, atypes) -> int ffi_status
;;
;; Every argument is an address or a small int; the structs are lib/_ctypes.py's.
;; ============================================================================
DEF_FUNC cx_prep_cif, PC_FRAME
    cmp rsi, 5
    jne cx_nargs
    CX_LOAD_INTS 5
    mov rdi, [rbp - PC_V]
    mov esi, [rbp - PC_V + 8]
    mov edx, [rbp - PC_V + 16]
    mov rcx, [rbp - PC_V + 24]
    mov r8, [rbp - PC_V + 32]
    call ffi_prep_cif wrt ..plt
    mov edi, eax
    call cx_ret_int
    leave
    ret
END_FUNC cx_prep_cif

;; ============================================================================
;; _ctypescore.prep_cif_var(cif, abi, nfixed, ntotal, rtype, atypes) -> int
;;
;; The variadic form, for a function whose argtypes cover only its fixed part.
;; ============================================================================
DEF_FUNC cx_prep_cif_var, PC_FRAME
    cmp rsi, 6
    jne cx_nargs
    CX_LOAD_INTS 6
    mov rdi, [rbp - PC_V]
    mov esi, [rbp - PC_V + 8]
    mov edx, [rbp - PC_V + 16]
    mov ecx, [rbp - PC_V + 24]
    mov r8, [rbp - PC_V + 32]
    mov r9, [rbp - PC_V + 40]
    call ffi_prep_cif_var wrt ..plt
    mov edi, eax
    call cx_ret_int
    leave
    ret
END_FUNC cx_prep_cif_var

;; ============================================================================
;; cx_swap_errno() -> exchanges the real errno with ours
;;
;; CPython swaps on the way in AND on the way out, so the caller's errno is
;; what it was before the call and ours is what the function left.
;; ============================================================================
DEF_FUNC cx_swap_errno
    call __errno_location wrt ..plt
    mov ecx, [rax]
    mov edx, [rel cx_errno]
    mov [rax], edx
    mov [rel cx_errno], ecx
    leave
    ret
END_FUNC cx_swap_errno

;; ============================================================================
;; _ctypescore.call(cif, fn, rvalue, avalues, use_errno) -> None
;;
;; ffi_call itself.  A callback the function makes runs Python inside it;
;; see the header for why that needs nothing more here.
;; ============================================================================
DEF_FUNC cx_call, PC_FRAME
    cmp rsi, 5
    jne cx_nargs
    CX_LOAD_INTS 5
    cmp qword [rbp - PC_V + 32], 0
    je .cc_call
    call cx_swap_errno
.cc_call:
    mov rdi, [rbp - PC_V]
    mov rsi, [rbp - PC_V + 8]
    mov rdx, [rbp - PC_V + 16]
    mov rcx, [rbp - PC_V + 24]
    call ffi_call wrt ..plt
    cmp qword [rbp - PC_V + 32], 0
    je .cc_done
    call cx_swap_errno
.cc_done:
    call cx_ret_none
    leave
    ret
END_FUNC cx_call

;; ============================================================================
;; _ctypescore.closure(cif, callable, out) -> int, the writable closure, or 0
;;
;; Writes the EXECUTABLE address -- the function pointer C will call -- into
;; the 8 bytes at `out`.  The callable is borrowed: lib/_ctypes.py keeps it,
;; and the cif, alive for as long as the closure.
;; ============================================================================
DEF_FUNC cx_closure, PC_FRAME
    cmp rsi, 3
    jne cx_nargs
    mov [rbp - PC_ARGS], rdi
    xor esi, esi
    call cx_arg_i64
    mov [rbp - PC_V], rax
    mov rdi, [rbp - PC_ARGS]
    mov esi, 2
    call cx_arg_i64
    mov [rbp - PC_V + 8], rax
    mov rax, [rbp - PC_ARGS]
    mov rax, [rax + 8]
    mov [rbp - PC_V + 16], rax  ; the callable, a pointer Value

    mov edi, CX_CLOSURE_SIZE
    lea rsi, [rbp - PC_V + 24]
    call ffi_closure_alloc wrt ..plt
    test rax, rax
    jz .cl_fail
    mov [rbp - PC_V + 32], rax
    mov rdi, rax
    mov rsi, [rbp - PC_V]
    lea rdx, [rel cx_tramp]
    mov rcx, [rbp - PC_V + 16]
    mov r8, [rbp - PC_V + 24]
    call ffi_prep_closure_loc wrt ..plt
    test eax, eax
    jnz .cl_free
    mov rax, [rbp - PC_V + 8]
    mov rcx, [rbp - PC_V + 24]
    mov [rax], rcx
    mov rdi, [rbp - PC_V + 32]
    call cx_ret_int
    leave
    ret
.cl_free:
    mov rdi, [rbp - PC_V + 32]
    call ffi_closure_free wrt ..plt
.cl_fail:
    xor edi, edi
    call cx_ret_int
    leave
    ret
END_FUNC cx_closure

;; ============================================================================
;; _ctypescore.closure_free(closure) -> None
;; ============================================================================
DEF_FUNC cx_closure_free
    cmp rsi, 1
    jne cx_nargs
    xor esi, esi
    call cx_arg_i64
    test rax, rax
    jz .cf_done
    mov rdi, rax
    call ffi_closure_free wrt ..plt
.cf_done:
    call cx_ret_none
    leave
    ret
END_FUNC cx_closure_free

;; ============================================================================
;; cx_tramp(rdi = ffi_cif*, rsi = return slot, rdx = void **args,
;;          rcx = user_data, the Python callable) -> nothing
;;
;; Called BY LIBFFI, from inside whatever C function is calling back.  Hands
;; the callable (ret, args) as two ints and drops whatever it answers.
;; ============================================================================
CT_UD    equ 8
CT_ARGS  equ 16
CT_V1    equ 24                 ; the Value pair, V0 below V1
CT_V0    equ 32
CT_FRAME equ 32                 ; + 0 pushes = 32, 16-aligned
DEF_FUNC cx_tramp, CT_FRAME
    mov [rbp - CT_UD], rcx
    mov [rbp - CT_ARGS], rdx
    mov rdi, rsi
    call int_from_i64
    V_PACK rax, rdx
    mov [rbp - CT_V0], rax
    mov rdi, [rbp - CT_ARGS]
    call int_from_i64
    V_PACK rax, rdx
    mov [rbp - CT_V1], rax

    mov qword [rel kw_names_pending], 0
    mov rdi, [rbp - CT_UD]
    lea rsi, [rbp - CT_V0]
    mov edx, 2
    call obj_call_n
    test rax, rax
    jz .ct_raised
    DECREF_V rax, rcx
    jmp .ct_out
.ct_raised:
    mov rdi, [rel current_exception]
    test rdi, rdi
    jz .ct_out
    mov qword [rel current_exception], 0
    call obj_decref
.ct_out:
    mov rax, [rbp - CT_V0]
    DECREF_V rax, rcx
    mov rax, [rbp - CT_V1]
    DECREF_V rax, rcx
    leave
    ret
END_FUNC cx_tramp

;; ============================================================================
;; _ctypescore.errno_get() -> int, the ctypes-private errno
;; ============================================================================
DEF_FUNC cx_errno_get
    movsxd rdi, dword [rel cx_errno]
    call cx_ret_int
    leave
    ret
END_FUNC cx_errno_get

;; ============================================================================
;; _ctypescore.errno_set(value) -> int, the old one
;; ============================================================================
ES_OLD   equ 8
ES_FRAME equ 16             ; + 0 pushes = 16, 16-aligned
DEF_FUNC cx_errno_set, ES_FRAME
    cmp rsi, 1
    jne cx_nargs
    movsxd rax, dword [rel cx_errno]
    mov [rbp - ES_OLD], rax
    xor esi, esi
    call cx_arg_i64
    mov [rel cx_errno], eax
    mov rdi, [rbp - ES_OLD]
    call cx_ret_int
    leave
    ret
END_FUNC cx_errno_set

;; ============================================================================
;; _ctypescore.errno_swap() -> None
;;
;; What a callback made with use_errno=True does around the Python call, the
;; mirror image of cx_call's two swaps.
;; ============================================================================
DEF_FUNC cx_errno_swap
    call cx_swap_errno
    call cx_ret_none
    leave
    ret
END_FUNC cx_errno_swap

;; ============================================================================
;; ctypes_module_create() -> rax = the module object
;; ============================================================================
CMC_FRAME equ 32            ; + 2 pushes = 48, 16-aligned
DEF_FUNC ctypes_module_create, CMC_FRAME
    push rbx
    push r12
    call dict_new
    mov r12, rax                ; MODULE_ADD_FUNC reads the dict from r12

    MODULE_ADD_FUNC cx_dlopen,       cn_dlopen
    MODULE_ADD_FUNC cx_dlsym,        cn_dlsym
    MODULE_ADD_FUNC cx_dlclose,      cn_dlclose
    MODULE_ADD_FUNC cx_dlerror,      cn_dlerror
    MODULE_ADD_FUNC cx_addr,         cn_addr
    MODULE_ADD_FUNC cx_read,         cn_read
    MODULE_ADD_FUNC cx_write,        cn_write
    MODULE_ADD_FUNC cx_strlen,       cn_strlen
    MODULE_ADD_FUNC cx_wcslen,       cn_wcslen
    MODULE_ADD_FUNC cx_prep_cif,     cn_prep_cif
    MODULE_ADD_FUNC cx_prep_cif_var, cn_prep_cif_var
    MODULE_ADD_FUNC cx_call,         cn_call
    MODULE_ADD_FUNC cx_closure,      cn_closure
    MODULE_ADD_FUNC cx_closure_free, cn_closure_free
    MODULE_ADD_FUNC cx_errno_get,    cn_errno_get
    MODULE_ADD_FUNC cx_errno_set,    cn_errno_set
    MODULE_ADD_FUNC cx_errno_swap,   cn_errno_swap

    lea rdi, [rel cn_name]
    call str_from_cstr_heap
    mov rbx, rax
    mov rdi, rax
    mov rsi, r12
    call module_new
    mov rbx, rax
    mov rdi, r12
    call obj_decref
    mov rax, rbx
    pop r12
    pop rbx
    leave
    ret
END_FUNC ctypes_module_create

section .rodata
cn_name:         db "_ctypescore", 0
cn_dlopen:       db "dlopen", 0
cn_dlsym:        db "dlsym", 0
cn_dlclose:      db "dlclose", 0
cn_dlerror:      db "dlerror", 0
cn_addr:         db "addr", 0
cn_read:         db "read", 0
cn_write:        db "write", 0
cn_strlen:       db "strlen", 0
cn_wcslen:       db "wcslen", 0
cn_prep_cif:     db "prep_cif", 0
cn_prep_cif_var: db "prep_cif_var", 0
cn_call:         db "call", 0
cn_closure:      db "closure", 0
cn_closure_free: db "closure_free", 0
cn_errno_get:    db "errno_get", 0
cn_errno_set:    db "errno_set", 0
cn_errno_swap:   db "errno_swap", 0
cx_e_buffer:     db `a bytes-like object is required, not '\x01'`, 0
