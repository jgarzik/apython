; timemod.asm - time module implementation
; Provides time.time(), time.sleep(), time.process_time() and time.monotonic()

%include "macros.inc"
%include "object.inc"

extern ap_malloc
extern obj_decref
extern obj_incref
extern str_from_cstr_heap
extern float_from_f64
extern dict_new
extern dict_set
extern module_new
extern builtin_func_new
extern none_singleton
extern raise_exception
extern exc_TypeError_type
extern exc_ValueError_type
extern exc_OverflowError_type
extern structseq_new
extern structseq_set
extern structseq_dealloc
extern structseq_repr
extern structseq_getattr
extern str_type
extern structseq_init_type
extern int_from_i64
extern str_new_heap
extern tuple_type
extern obj_as_index
extern type_type
extern localtime_r
extern gmtime_r
extern mktime
extern strftime
extern ap_free
extern ap_strlen
extern int_to_i64
extern obj_dealloc
extern tuple_new

;; ============================================================================
;; tm_add_int(rdi = the value, rsi = its name as a C string) -> void
;; One int in the module dict, with the dict in r12 as everything here has it.
;; ============================================================================
TAI_VAL   equ 8
TAI_NAME  equ 16
TAI_OBJ   equ 24
TAI_FRAME equ 32            ; + 0 pushes = 32
DEF_FUNC_LOCAL tm_add_int, TAI_FRAME
    mov [rbp - TAI_VAL], rdi
    mov [rbp - TAI_NAME], rsi
    extern int_from_i64
    call int_from_i64
    V_PACK rax, rdx
    mov [rbp - TAI_OBJ], rax
    mov rdi, [rbp - TAI_NAME]
    call str_from_cstr_heap
    push rax
    mov rdi, r12
    mov rsi, rax
    mov rdx, [rbp - TAI_OBJ]
    call dict_set
    pop rdi
    call obj_decref
    mov rdi, [rbp - TAI_OBJ]
    DECREF_V rdi, rsi
    leave
    ret
END_FUNC tm_add_int

;; TIME_ADD_FUNC impl, name -- the module dict is in r12, so this is
;; MODULE_ADD_FUNC by another name; it is spelled out here because the file
;; predates the macro and the other six registrations still use the long form.
extern tzset
extern tzname
extern timezone
extern daylight

%macro TIME_ADD_FUNC 2
    lea rdi, [rel %1]
    lea rsi, [rel %2]
    call builtin_func_new
    push rax
    lea rdi, [rel %2]
    call str_from_cstr_heap
    push rax
    mov rdi, r12
    mov rsi, rax
    mov rdx, [rsp + 8]
    call dict_set
    pop rdi
    call obj_decref
    pop rdi
    call obj_decref
%endmacro

;; TIME_FIELD slot, tm_offset, bias -- one int field of the struct_time.
%macro TIME_FIELD 3
    mov rdi, [rbp - TFS_TM]
    mov eax, [rdi + %2]
    add eax, %3
    movsxd rdi, eax
    call int_from_i64
    V_PACK rax, rdx             ; it hands back a (payload, tag) pair
    mov rdx, rax
    mov rdi, [rbp - TFS_OBJ]
    mov esi, %1
    call structseq_set          ; one numbering across the tuple and the tail
%endmacro

;; TIME_READ slot, tm_offset, bias -- the same field, read back.
%macro TIME_READ 3
    mov rax, [rbp - TRS_SEQ]
    mov rax, [rax + PyTupleObject.ob_item]
    mov rdi, [rax + %1*8]
    V_UNPACK rdi, rdx
    call obj_as_index
    add rax, %3
    mov [rbx + %2], eax
%endmacro

; Clock IDs for clock_gettime
CLOCK_REALTIME           equ 0
CLOCK_MONOTONIC          equ 1
CLOCK_PROCESS_CPUTIME_ID equ 2
CLOCK_THREAD_CPUTIME_ID  equ 3
CLOCK_MONOTONIC_RAW      equ 4
CLOCK_REALTIME_COARSE    equ 5
CLOCK_MONOTONIC_COARSE   equ 6
CLOCK_BOOTTIME           equ 7
CLOCK_REALTIME_ALARM     equ 8
CLOCK_BOOTTIME_ALARM     equ 9
CLOCK_TAI                equ 11
SYS_clock_gettime        equ 228
SYS_clock_settime        equ 227
SYS_clock_getres         equ 229

;; ============================================================================
;; time_process_time_func(PyObject **args, int64_t nargs) -> rax = Value
;; Returns process CPU time as a float (seconds)
;; ============================================================================
; A struct timespec, filled by clock_gettime: tv_sec then tv_nsec.
TS_SEC    equ 16
TS_NSEC   equ 8
DEF_FUNC time_process_time_func, 16
    test rsi, rsi
    jne .pt_error

    ; clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &timespec)
    ; timespec is at [rbp - TS_SEC]: tv_sec at [rbp - TS_SEC], tv_nsec at [rbp - TS_NSEC]
    mov eax, 228            ; __NR_clock_gettime
    mov edi, CLOCK_PROCESS_CPUTIME_ID
    lea rsi, [rbp - TS_SEC]
    syscall

    ; Convert to float: seconds + nanoseconds/1e9
    ; tv_sec at [rbp - TS_SEC], tv_nsec at [rbp - TS_NSEC]
    cvtsi2sd xmm0, qword [rbp - TS_SEC]    ; seconds
    cvtsi2sd xmm1, qword [rbp - TS_NSEC]     ; nanoseconds
    movsd xmm2, [rel tm_1e9]
    divsd xmm1, xmm2
    addsd xmm0, xmm1

    call float_from_f64
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.pt_error:
    RAISE exc_TypeError_type, "process_time() takes no arguments"
END_FUNC time_process_time_func

;; ============================================================================
;; time_monotonic_func(PyObject **args, int64_t nargs) -> rax = Value
;; Returns monotonic clock as a float (seconds)
;; ============================================================================
DEF_FUNC time_monotonic_func, 16
    test rsi, rsi
    jne .mono_error

    mov eax, 228            ; __NR_clock_gettime
    mov edi, CLOCK_MONOTONIC
    lea rsi, [rbp - TS_SEC]
    syscall

    cvtsi2sd xmm0, qword [rbp - TS_SEC]
    cvtsi2sd xmm1, qword [rbp - TS_NSEC]
    movsd xmm2, [rel tm_1e9]
    divsd xmm1, xmm2
    addsd xmm0, xmm1

    call float_from_f64
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.mono_error:
    RAISE exc_TypeError_type, "monotonic() takes no arguments"
END_FUNC time_monotonic_func

;; ============================================================================
;; time_perf_counter_func(PyObject **args, int64_t nargs) -> rax = Value
;; The highest-resolution clock, in seconds, with an undefined origin -- so
;; only differences mean anything.  On Linux that is CLOCK_MONOTONIC, the same
;; source monotonic() reads; CPython keeps them separate because on other
;; platforms they are not, and because timeit and every benchmark in the
;; stdlib ask for this name rather than that one.
;; ============================================================================
DEF_FUNC time_perf_counter_func, 16
    test rsi, rsi
    jne .perf_error

    mov eax, 228            ; __NR_clock_gettime
    mov edi, CLOCK_MONOTONIC
    lea rsi, [rbp - TS_SEC]
    syscall

    cvtsi2sd xmm0, qword [rbp - TS_SEC]
    cvtsi2sd xmm1, qword [rbp - TS_NSEC]
    movsd xmm2, [rel tm_1e9]
    divsd xmm1, xmm2
    addsd xmm0, xmm1

    call float_from_f64
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.perf_error:
    RAISE exc_TypeError_type, "perf_counter() takes no arguments"
END_FUNC time_perf_counter_func

;; ============================================================================
;; DEF_CLOCK_NS %1 = the function, %2 = the CLOCK_* to read, %3 = the message
;;
;; The same clock the float function beside it reads, reported as an integer
;; count of nanoseconds instead.  That is the whole point of the *_ns family:
;; a double carries 53 bits of mantissa, so seconds-since-the-epoch loses
;; resolution below a microsecond around now and keeps losing it, and
;; asyncio, timeit and every deadline in the stdlib ask for these names.
;;
;; int_from_i64, not V_PACK_I64: time_ns() is about 1.7e18, far outside the
;; +-2^50 an immediate holds, so it has to be free to box.
;; ============================================================================
%macro DEF_CLOCK_NS 3
DEF_FUNC %1, 16
    test rsi, rsi
    jne %%bad

    mov eax, 228            ; __NR_clock_gettime
    mov edi, %2
    lea rsi, [rbp - TS_SEC]
    syscall

    mov rax, [rbp - TS_SEC]
    mov ecx, 1000000000
    imul rax, rcx
    add rax, [rbp - TS_NSEC]
    mov rdi, rax
    call int_from_i64
    leave
    V_PACK rax, rdx         ; builtins return one Value
    ret

%%bad:
    RAISE exc_TypeError_type, %3
END_FUNC %1
%endmacro

DEF_CLOCK_NS time_time_ns_func, CLOCK_REALTIME, "time_ns() takes no arguments"
DEF_CLOCK_NS time_monotonic_ns_func, CLOCK_MONOTONIC, "monotonic_ns() takes no arguments"
DEF_CLOCK_NS time_perf_counter_ns_func, CLOCK_MONOTONIC, "perf_counter_ns() takes no arguments"
DEF_CLOCK_NS time_process_time_ns_func, CLOCK_PROCESS_CPUTIME_ID, "process_time_ns() takes no arguments"

;; ============================================================================
;; time_clock_gettime_func(rdi = the argument array, rsi = how many)
;;   -> rax = a float Value: the clock's reading in seconds
;;
;; The same syscall the five fixed readers above make, with the clock taken
;; from an argument instead of a literal -- and that is exactly why the
;; RETURN VALUE has to be checked here and does not have to be there.  A
;; hardcoded CLOCK_MONOTONIC cannot fail; a caller-supplied number can, and
;; EINVAL for a clock this kernel does not have is the answer rather than a
;; timespec of whatever was on the stack.
;;
;; None of the five existing readers checks it.  That is safe for them and
;; would not be for these, which is the whole distinction.
;; ============================================================================
TCG_TS    equ 16            ; struct timespec: tv_sec, tv_nsec
TCG_FRAME equ 24            ; + 1 push = 32, 16-aligned
extern int_from_i64
DEF_FUNC time_clock_gettime_func, TCG_FRAME
    push rbx
    test rsi, rsi
    jz .tcg_args
    mov rdi, [rdi]
    call tm_clock_id_arg
    mov rdi, rax
    lea rsi, [rbp - TCG_TS]
    mov eax, SYS_clock_gettime
    syscall
    cmp rax, -4095
    jae .tcg_failed
    mov rax, [rbp - TCG_TS]
    cvtsi2sd xmm0, rax
    mov rax, [rbp - TCG_TS + 8]
    cvtsi2sd xmm1, rax
    divsd xmm1, [rel tm_1e9]
    addsd xmm0, xmm1
    movq rax, xmm0
    V_FROM_F64 rax, rcx
    pop rbx
    leave
    ret
.tcg_failed:
    mov rdi, rax
    neg rdi
    xor esi, esi
    extern raise_oserror
    call raise_oserror
.tcg_args:
    RAISE exc_TypeError_type, "clock_gettime() takes exactly 1 argument"
END_FUNC time_clock_gettime_func

;; ============================================================================
;; time_clock_gettime_ns_func(rdi = the arguments, rsi = how many)
;;   -> rax = an int Value: the same reading in nanoseconds
;; ============================================================================
DEF_FUNC time_clock_gettime_ns_func, TCG_FRAME
    push rbx
    test rsi, rsi
    jz .tcgn_args
    mov rdi, [rdi]
    call tm_clock_id_arg
    mov rdi, rax
    lea rsi, [rbp - TCG_TS]
    mov eax, SYS_clock_gettime
    syscall
    cmp rax, -4095
    jae .tcgn_failed
    mov rax, [rbp - TCG_TS]
    mov ecx, 1000000000
    imul rax, rcx
    add rax, [rbp - TCG_TS + 8]
    mov rdi, rax
    call int_from_i64
    V_PACK rax, rdx
    pop rbx
    leave
    ret
.tcgn_failed:
    mov rdi, rax
    neg rdi
    xor esi, esi
    call raise_oserror
.tcgn_args:
    RAISE exc_TypeError_type, "clock_gettime_ns() takes exactly 1 argument"
END_FUNC time_clock_gettime_ns_func

;; ============================================================================
;; time_clock_getres_func(rdi = the arguments, rsi = how many)
;;   -> rax = a float Value: the clock's resolution in seconds
;; ============================================================================
DEF_FUNC time_clock_getres_func, TCG_FRAME
    push rbx
    test rsi, rsi
    jz .tcr_args
    mov rdi, [rdi]
    call tm_clock_id_arg
    mov rdi, rax
    lea rsi, [rbp - TCG_TS]
    mov eax, SYS_clock_getres
    syscall
    cmp rax, -4095
    jae .tcr_failed
    mov rax, [rbp - TCG_TS]
    cvtsi2sd xmm0, rax
    mov rax, [rbp - TCG_TS + 8]
    cvtsi2sd xmm1, rax
    divsd xmm1, [rel tm_1e9]
    addsd xmm0, xmm1
    movq rax, xmm0
    V_FROM_F64 rax, rcx
    pop rbx
    leave
    ret
.tcr_failed:
    mov rdi, rax
    neg rdi
    xor esi, esi
    call raise_oserror
.tcr_args:
    RAISE exc_TypeError_type, "clock_getres() takes exactly 1 argument"
END_FUNC time_clock_getres_func

;; ============================================================================
;; tm_clock_id_arg(rdi = a Value) -> rax = the clock id
;;
;; An int, and nothing else.  CPython's clinic takes a clockid_t, which means
;; __index__ is honoured; obj_as_index is that.
;; ============================================================================
extern obj_as_index
DEF_FUNC_LOCAL tm_clock_id_arg, 16
    ; obj_as_index takes the legacy (payload, tag) PAIR, not a Value -- hand
    ; it only rdi and it reads whatever was in edx as the tag, which made
    ; clock_gettime("x") an EINVAL from the syscall instead of the TypeError
    ; it owes.
    V_UNPACK rdi, rdx
    call obj_as_index
    leave
    ret
END_FUNC tm_clock_id_arg

;; ============================================================================
;; time_thread_time_ns_func(rdi, rsi) -> rax = an int Value: the nanoseconds
;;   of CPU this thread has used
;;
;; CLOCK_THREAD_CPUTIME_ID.  get_clock_info has described this clock all
;; along -- the comment there says the function is what is missing -- and
;; with one thread it answers what process_time does, which is the right
;; answer rather than a coincidence.
;; ============================================================================
DEF_CLOCK_NS time_thread_time_ns_func, CLOCK_THREAD_CPUTIME_ID, "thread_time_ns() takes no arguments"

;; ============================================================================
;; time_thread_time_func(rdi, rsi) -> rax = a float Value: the same in seconds
;; ============================================================================
TT_TS    equ 16
TT_FRAME equ 24             ; + 1 push = 32, 16-aligned
DEF_FUNC time_thread_time_func, TT_FRAME
    push rbx
    test rsi, rsi
    jnz .tt_args
    mov eax, SYS_clock_gettime
    mov edi, CLOCK_THREAD_CPUTIME_ID
    lea rsi, [rbp - TT_TS]
    syscall
    mov rax, [rbp - TT_TS]
    cvtsi2sd xmm0, rax
    mov rax, [rbp - TT_TS + 8]
    cvtsi2sd xmm1, rax
    divsd xmm1, [rel tm_1e9]
    addsd xmm0, xmm1
    movq rax, xmm0
    V_FROM_F64 rax, rcx
    pop rbx
    leave
    ret
.tt_args:
    RAISE exc_TypeError_type, "thread_time() takes no arguments"
END_FUNC time_thread_time_func

;; ============================================================================
;; time_get_clock_info_func(PyObject **args, int64_t nargs) -> rax = Value
;;
;; What a named clock is and how good it is, as the types.SimpleNamespace with
;; four fields CPython answers with.  It is here because asyncio cannot start
;; without it: BaseEventLoop.__init__ opens with
;;
;;     self._clock_resolution = time.get_clock_info('monotonic').resolution
;;
;; so every asyncio module -- gather, TaskGroup, timeout, the streams -- died
;; on an AttributeError before running a line of its own.
;;
;; Every one of the five is clock_gettime, whose timespec counts nanoseconds,
;; so the resolution is 1e-09 for all of them; CPython reports the same figure
;; for the same reason, answering with clock_getres' number rather than the
;; clock's true precision.  A fifth table column holding one constant five
;; times would say less than this paragraph does.
;;
;; thread_time is in the table although time.thread_time() is not in this
;; module.  get_clock_info describes the platform's clocks, and refusing a
;; name CPython knows would be the worse answer of the two.
;; ============================================================================
TCI_ARGS  equ 8             ; the name argument, as handed to us
TCI_TMP   equ 16            ; whichever owned field value is in flight
TCI_FRAME equ 32            ; + 2 pushes = 48, 16-aligned

extern namespace_new
extern namespace_set
extern bool_true
extern bool_false
extern raise_type_error_counted
extern raise_type_error_with_name
extern none_singleton
extern ap_strcmp
extern ap_strlen
extern str_type
extern type_is_subtype

DEF_FUNC time_get_clock_info_func, TCI_FRAME
    push rbx
    push r12
    cmp rsi, 1
    jne .gci_arity

    mov rax, [rdi]
    mov [rbp - TCI_ARGS], rax
    V_TEST_PTR rax, rdx
    ja .gci_not_str
    test rax, rax
    jz .gci_not_str
    mov rdi, [rax + PyObject.ob_type]
    lea rsi, [rel str_type]
    call type_is_subtype            ; PyUnicode_Check takes a subclass
    test eax, eax
    jz .gci_not_str

    ; The table below is scanned with a C string compare, which stops at the
    ; first NUL -- so "time\0junk" would match the row for "time".  CPython's
    ; converter refuses an embedded NUL before the lookup happens at all, and
    ; so does this: a str that is shorter as a C string than its ob_size says
    ; has one in it.
    mov rbx, [rbp - TCI_ARGS]
    lea rdi, [rbx + PyStrObject.data]
    call ap_strlen
    cmp rax, [rbx + PyStrObject.ob_size]
    jne .gci_embedded_nul

    lea rbx, [rel tci_table]
.gci_scan:
    cmp qword [rbx + TCI_NAME], 0
    je .gci_unknown
    mov rdi, [rbp - TCI_ARGS]
    lea rdi, [rdi + PyStrObject.data]
    mov rsi, [rbx + TCI_NAME]
    call ap_strcmp
    test eax, eax
    jz .gci_found
    add rbx, TCI_ROW_SIZE
    jmp .gci_scan

.gci_found:
    call namespace_new
    test rax, rax
    jz .gci_fail
    mov r12, rax

    ; implementation: an owned str, released once namespace_set's dict_set has
    ; taken its own reference.
    mov rdi, [rbx + TCI_IMPL]
    call str_from_cstr_heap
    test rax, rax
    jz .gci_fail_ns
    mov [rbp - TCI_TMP], rax
    mov rdi, r12
    lea rsi, [rel tci_f_impl]
    mov rdx, rax
    call namespace_set
    mov rdi, [rbp - TCI_TMP]
    call obj_decref

    ; monotonic and adjustable: the two immortal singletons, which the store
    ; INCREFs and we never owned.
    lea rdx, [rel bool_false]
    cmp qword [rbx + TCI_MONO], 0
    je .gci_mono
    lea rdx, [rel bool_true]
.gci_mono:
    mov rdi, r12
    lea rsi, [rel tci_f_mono]
    call namespace_set

    lea rdx, [rel bool_false]
    cmp qword [rbx + TCI_ADJ], 0
    je .gci_adj
    lea rdx, [rel bool_true]
.gci_adj:
    mov rdi, r12
    lea rsi, [rel tci_f_adj]
    call namespace_set

    ; resolution.  A float Value is NaN-boxed, so V_PACK allocates nothing and
    ; there is nothing to own -- DECREF_V is here because the ownership rule
    ; and not the representation is what a reader should have to follow.
    movsd xmm0, [rel tci_resolution]
    call float_from_f64
    V_PACK rax, rdx
    mov [rbp - TCI_TMP], rax
    mov rdi, r12
    lea rsi, [rel tci_f_res]
    mov rdx, rax
    call namespace_set
    mov rdi, [rbp - TCI_TMP]
    DECREF_V rdi, rax

    mov rax, r12
    pop r12
    pop rbx
    leave
    ret

.gci_fail_ns:
    mov rdi, r12
    call obj_decref
.gci_fail:
    pop r12
    pop rbx
    leave
    RET_NULL
    ret

.gci_arity:
    CSTRING rdi, "get_clock_info() takes exactly 1 argument ("
    CSTRING rdx, " given)"
    call raise_type_error_counted

.gci_not_str:
    ; CPython's _PyArg_BadArgument spells None as "None" rather than as its
    ; type; the shared \x01 helper spells every type the same way, and it has
    ; fifty-odd other callers whose wording this must not move.
    mov rsi, [rbp - TCI_ARGS]
    lea rax, [rel none_singleton]
    cmp rsi, rax
    je .gci_not_str_none
    CSTRING rdi, `get_clock_info() argument 1 must be str, not \x01`
    call raise_type_error_with_name
.gci_not_str_none:
    RAISE exc_TypeError_type, "get_clock_info() argument 1 must be str, not None"

.gci_embedded_nul:
    RAISE exc_ValueError_type, "embedded null character"

.gci_unknown:
    RAISE exc_ValueError_type, "unknown clock"
END_FUNC time_get_clock_info_func

;; ============================================================================
;; time_time_func(PyObject **args, int64_t nargs) -> rax = Value
;; Seconds since the epoch, as a float.  The wall clock, where monotonic is
;; the one that cannot go backwards.
;; ============================================================================
DEF_FUNC time_time_func, 16
    test rsi, rsi
    jne .time_error

    mov eax, 228            ; __NR_clock_gettime
    mov edi, CLOCK_REALTIME
    lea rsi, [rbp - TS_SEC]
    syscall

    cvtsi2sd xmm0, qword [rbp - TS_SEC]
    cvtsi2sd xmm1, qword [rbp - TS_NSEC]
    movsd xmm2, [rel tm_1e9]
    divsd xmm1, xmm2
    addsd xmm0, xmm1

    call float_from_f64
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.time_error:
    RAISE exc_TypeError_type, "time() takes no arguments"
END_FUNC time_time_func

;; ============================================================================
;; time_sleep_func(PyObject **args, int64_t nargs) -> None
;; nanosleep, with the argument in seconds as an int or a float.
;; ============================================================================
TSL_SEC   equ 16
TSL_NSEC  equ 8
TSL_ARG   equ 24            ; the argument Value, kept for the overflow message
; What nanosleep did NOT sleep, when a signal cut it short.  The two words
; are a struct timespec and grow upward, so the slot names the lower of them.
TSL_REM   equ 40
TSL_FRAME equ 48            ; + 0 pushes = 48
DEF_FUNC time_sleep_func, TSL_FRAME
    cmp rsi, 1
    jne .sleep_error

    mov rdi, [rdi]
    mov [rbp - TSL_ARG], rdi
    V_UNPACK rdi, rsi
    extern float_binop_accepts
    push rdi
    push rsi
    call float_binop_accepts
    pop rsi
    pop rdi
    test eax, eax
    jz .sleep_type_error
    extern float_to_f64
    call float_to_f64           ; seconds, as a double

    ; NaN is its own answer, and CPython gives it its own wording -- it is not
    ; "negative", which is what this used to call it.
    ucomisd xmm0, xmm0
    jp .sleep_nan

    ; The delay has to survive the trip through nanoseconds.  CPython's
    ; _PyTime_t is an int64 count of them, so it rejects anything whose
    ; product with 1e9 will not fit one, and that check has to come BEFORE the
    ; negative test: -inf and -1e300 are overflows in CPython, not "sleep
    ; length must be non-negative".
    ;
    ; Without it, cvttsd2si below answered INT64_MIN for any argument out of
    ; range -- the x86 "integer indefinite" -- and that went into tv_sec.  So
    ; time.sleep(float('inf')) returned at once instead of raising, and
    ; time.sleep(10**10) slept for three centuries.
    movsd xmm1, xmm0
    mulsd xmm1, [rel tm_1e9]        ; the delay in nanoseconds
    ucomisd xmm1, [rel tm_i64_max]
    jae .sleep_overflow
    ucomisd xmm1, [rel tm_i64_min]
    jb .sleep_overflow

    xorpd xmm1, xmm1
    ucomisd xmm0, xmm1
    jb .sleep_value_error

    ; Split into whole seconds and nanoseconds for struct timespec.
    roundsd xmm1, xmm0, 1       ; floor
    subsd xmm0, xmm1
    cvttsd2si rax, xmm1
    mov [rbp - TSL_SEC], rax
    mulsd xmm0, [rel tm_1e9]
    cvttsd2si rax, xmm0
    mov [rbp - TSL_NSEC], rax

    ; PEP 475: a signal interrupts the SYSCALL, not the sleep.  CPython runs
    ; whatever arrived and then sleeps out the remainder, and only a handler
    ; that raises ends it early.  This passed no remainder and never retried,
    ; so an alarm during a two-second sleep returned after one -- and the
    ; handler did not run either, because nothing on the way out looked at
    ; the pending flag.
.sleep_again:
    mov eax, 35                 ; __NR_nanosleep
    lea rdi, [rbp - TSL_SEC]
    lea rsi, [rbp - TSL_REM]
    syscall
    cmp rax, -4                 ; -EINTR
    jne .sleep_finished
    extern signal_run_pending
    call signal_run_pending
    test eax, eax
    jnz .sleep_handler_raised
    mov rax, [rbp - TSL_REM]
    mov [rbp - TSL_SEC], rax
    mov rax, [rbp - TSL_REM + 8]
    mov [rbp - TSL_NSEC], rax
    ; A remainder of zero is a sleep that finished; retrying would be a
    ; nanosleep(0) that returns at once, which is harmless but pointless.
    or rax, [rbp - TSL_SEC]
    jnz .sleep_again

.sleep_finished:
    extern none_singleton
    lea rax, [rel none_singleton]
    INCREF rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret

.sleep_handler_raised:
    ; The handler raised, and that is the answer: a NULL Value with the
    ; exception recorded, which is what signal_run_pending leaves behind.
    xor eax, eax
    xor edx, edx
    leave
    ret

.sleep_type_error:
    RAISE exc_TypeError_type, "sleep() argument must be a number"
.sleep_nan:
    extern exc_ValueError_type
    RAISE exc_ValueError_type, "Invalid value NaN (not a number)"
.sleep_overflow:
    ; CPython reaches the same overflow by two roads and says so differently:
    ; an int is rejected converting to _PyTime_t, a float converting back out
    ; to the platform's timespec.  The wording is what a program greps for.
    extern exc_OverflowError_type
    mov rax, [rbp - TSL_ARG]
    V_IS_FLOAT rax, rcx
    jbe .sleep_overflow_float
    RAISE exc_OverflowError_type, \
          "timestamp too large to convert to C _PyTime_t"
.sleep_overflow_float:
    RAISE exc_OverflowError_type, \
          "timestamp out of range for platform time_t"
.sleep_value_error:
    RAISE exc_ValueError_type, "sleep length must be non-negative"
.sleep_error:
    RAISE exc_TypeError_type, "sleep() takes exactly one argument"
END_FUNC time_sleep_func

;; ============================================================================
;; time_strptime_func(rdi = the argument array, rsi = how many)
;;   -> rax = a struct_time Value, or 0 with the exception pending
;;
;; CPython's time.strptime is C only in name: it imports _strptime and calls
;; _strptime_time, because the parsing is a regex over locale tables and has
;; no honest assembly form.  This does the same, and the import is LAZY --
;; _strptime imports `time`, so doing it at module init would close the
;; circle before this module exists.
;;
;; The looked-up function is cached for the process, the way deprecation_warn
;; caches _warnings.warn and for the same reason: the import is the expensive
;; half and it cannot change.
;; ============================================================================
;; The argument array grows UPWARD from its base, so its offset is the
;; LARGER number: args[0] is at [rbp - TSP_ARGS] and args[1] eight bytes
;; above it.  Writing TSP_ARGS as 8 put args[1] at [rbp], which is the saved
;; rbp.
TSP_ARGS  equ 24            ; the two Values handed to _strptime_time
TSP_NARGS equ 32            ; how many -- rsi does not survive the import
TSP_TMP   equ 40
TSP_MOD   equ 48            ; the module, and then the function, while looked up
TSP_KW    equ 56            ; the parked kw_names_pending
TSP_FRAME equ 72            ; + 1 push = 80, 16-aligned
extern import_module
extern dict_get
extern obj_incref
extern obj_call_n
DEF_FUNC time_strptime_func, TSP_FRAME
    push rbx
    mov rbx, rdi
    mov [rbp - TSP_NARGS], rsi

    cmp qword [rel tm_strptime_impl], 0
    jne .tsp_have

    ; The pending keyword names belong to the call in flight, not to the
    ; import about to run a module body.
    mov rax, [gs:ThreadState.kw_names_pending]
    mov [rbp - TSP_KW], rax
    mov qword [gs:ThreadState.kw_names_pending], 0

    lea rdi, [rel tm_strptime_mod]
    call str_from_cstr_heap
    mov [rbp - TSP_TMP], rax
    mov rdi, rax
    xor esi, esi
    xor edx, edx
    call import_module
    mov [rbp - TSP_MOD], rax
    mov rdi, [rbp - TSP_TMP]
    call obj_decref
    cmp qword [rbp - TSP_MOD], 0
    je .tsp_no_impl

    lea rdi, [rel tm_strptime_attr]
    call str_from_cstr_heap
    mov [rbp - TSP_TMP], rax
    mov rdi, [rbp - TSP_MOD]
    mov rdi, [rdi + PyModuleObject.mod_dict]
    mov rsi, rax
    call dict_get
    mov [rbp - TSP_MOD], rax
    mov rdi, [rbp - TSP_TMP]
    call obj_decref
    mov rax, [rbp - TSP_MOD]
    test rax, rax
    jz .tsp_no_impl
    mov rdi, rax
    call obj_incref
    mov rax, [rbp - TSP_MOD]
    mov [rel tm_strptime_impl], rax

    mov rax, [rbp - TSP_KW]
    mov [gs:ThreadState.kw_names_pending], rax

.tsp_have:
    ; strptime(string) and strptime(string, format), which is CPython's
    ; signature; _strptime_time has the same default.
    mov rsi, [rbp - TSP_NARGS]
    test rsi, rsi
    jz .tsp_args
    cmp rsi, 2
    ja .tsp_args
    mov qword [rbp - TSP_TMP], 0
    mov rax, [rbx]
    mov [rbp - TSP_ARGS], rax
    cmp rsi, 2
    jne .tsp_default_format
    mov rax, [rbx + 8]
    mov [rbp - TSP_ARGS + 8], rax
    jmp .tsp_call
.tsp_default_format:
    lea rdi, [rel tm_strptime_default]
    call str_from_cstr_heap
    test rax, rax
    jz .tsp_fail
    mov [rbp - TSP_ARGS + 8], rax
    mov [rbp - TSP_TMP], rax            ; ours to release
.tsp_call:
    mov rdi, [rel tm_strptime_impl]
    lea rsi, [rbp - TSP_ARGS]
    mov edx, 2
    call obj_call_n
    mov [rbp - TSP_MOD], rax            ; the answer, across the release
    mov rdi, [rbp - TSP_TMP]
    test rdi, rdi
    jz .tsp_done
    call obj_decref
.tsp_done:
    mov rax, [rbp - TSP_MOD]
    pop rbx
    leave
    ret

.tsp_no_impl:
    mov rax, [rbp - TSP_KW]
    mov [gs:ThreadState.kw_names_pending], rax
    RAISE exc_TypeError_type, "strptime() needs the _strptime module"
.tsp_fail:
    xor eax, eax
    xor edx, edx
    pop rbx
    leave
    ret
.tsp_args:
    RAISE exc_TypeError_type, "strptime() takes 1 or 2 arguments"
END_FUNC time_strptime_func

section .rodata
tm_strptime_mod:     db "_strptime", 0
tm_strptime_attr:    db "_strptime_time", 0
tm_strptime_default: db "%a %b %d %H:%M:%S %Y", 0
section .bss
; _strptime._strptime_time, looked up once and kept for the process.
tm_strptime_impl: resq 1
section .text

;; ============================================================================
;; tm_publish_tz() -> nothing; r12 = the module dict
;;
;; tzset(3) and the four names it fills: tzname, timezone, altzone, daylight.
;; Called at import and again by time.tzset(), which is the only reason the
;; module dict is kept in a global -- a caller that changes $TZ and calls
;; tzset() has to see the new zone in these four, and nothing else in this
;; file needs the dict after import.
;; ============================================================================
DEF_FUNC_LOCAL tm_publish_tz, 16      ; + 0 pushes = 16, 16-aligned
    call tzset
    lea rax, [rel tzname]
    mov rdi, [rax]
    call str_from_cstr_heap
    push rax
    lea rax, [rel tzname]
    mov rdi, [rax + 8]
    call str_from_cstr_heap
    push rax
    mov edi, 2
    call tuple_new
    mov rcx, [rax + PyTupleObject.ob_item]
    pop rdx
    mov [rcx + 8], rdx
    pop rdx
    mov [rcx], rdx
    push rax
    lea rdi, [rel tm_tzname]
    call str_from_cstr_heap
    push rax
    mov rdi, r12
    mov rsi, rax
    mov rdx, [rsp + 8]
    call dict_set
    pop rdi
    call obj_decref
    pop rdi
    call obj_decref

    ; The offset west of UTC in seconds, as CPython reports it: `timezone` is
    ; standard time, `altzone` is the same less an hour when the zone has DST,
    ; and `daylight` says whether it has any.
    lea rax, [rel timezone]
    mov rdi, [rax]
    lea rsi, [rel tm_timezone]
    call tm_add_int
    lea rax, [rel timezone]
    mov rdi, [rax]
    lea rcx, [rel daylight]
    mov ecx, [rcx]
    test ecx, ecx
    jz .ptz_no_dst
    sub rdi, 3600
.ptz_no_dst:
    lea rsi, [rel tm_altzone]
    call tm_add_int
    lea rax, [rel daylight]
    movsxd rdi, dword [rax]
    lea rsi, [rel tm_daylight]
    call tm_add_int

    leave
    ret
END_FUNC tm_publish_tz

;; ============================================================================
;; time_tzset_func(rdi = the arguments, rsi = how many) -> rax = None
;; Re-reads $TZ and republishes the four names it sets.
;; ============================================================================
DEF_FUNC time_tzset_func, 16          ; + 0 pushes = 16, 16-aligned
    test rsi, rsi
    jnz .tzs_args
    push r12
    push r12                            ; a pair, so the call stays aligned
    mov r12, [rel tm_module_dict]
    test r12, r12
    jz .tzs_none
    call tm_publish_tz
.tzs_none:
    pop r12
    pop r12
    lea rax, [rel none_singleton]
    INCREF rax
    mov edx, TAG_PTR
    leave
    ret
.tzs_args:
    RAISE exc_TypeError_type, "tzset() takes no arguments"
END_FUNC time_tzset_func

section .bss
; The `time` module's dict, so tzset() can republish into it.  Borrowed: the
; module owns it for the life of the interpreter.
tm_module_dict: resq 1
section .text

;; ============================================================================
;; time_module_create() -> PyObject*
;; Creates and returns the time module
;; ============================================================================
DEF_FUNC time_module_create
    push rbx
    push r12

    ; Create module dict
    call dict_new
    mov r12, rax            ; r12 = module dict

    ; Add process_time function
    lea rdi, [rel time_process_time_func]
    lea rsi, [rel tm_process_time]
    call builtin_func_new
    push rax
    lea rdi, [rel tm_process_time]
    call str_from_cstr_heap
    push rax
    mov rdi, r12
    mov rsi, rax
    mov rdx, [rsp + 8]
    call dict_set
    pop rdi
    call obj_decref
    pop rdi
    call obj_decref

    ; --- localtime / gmtime / mktime / strftime, and struct_time ---
    ;
    ; logging, hashlib and random all reach time.localtime at import.  The
    ; calendar arithmetic and the format language are libc's -- localtime_r,
    ; gmtime_r and strftime are already linked for the compiler's strtod --
    ; so what is here is the conversion either way.
    TIME_ADD_FUNC time_localtime_func, tm_localtime
    TIME_ADD_FUNC time_gmtime_func,    tm_gmtime
    TIME_ADD_FUNC time_mktime_func,    tm_mktime
    TIME_ADD_FUNC time_strftime_func,  tm_strftime
    TIME_ADD_FUNC time_asctime_func,   tm_asctime
    TIME_ADD_FUNC time_ctime_func,     tm_ctime

    ; asyncio's event loop asks for this before it does anything else.
    TIME_ADD_FUNC time_get_clock_info_func, tci_get_clock_info

    ; --- tzname / timezone / altzone / daylight ---
    ;
    ; The four glibc sets from $TZ, and _strptime reads tzname
    ; unconditionally at import.  tzset() is what fills them; localtime_r
    ; calls it too, but not before this runs.
    ; The four names glibc sets from $TZ, published into the module dict.
    ; time.tzset() does the same work again, which is what makes it a
    ; function rather than a no-op: a program that changes $TZ and calls it
    ; has to see the new zone here.
    mov [rel tm_module_dict], r12
    call tm_publish_tz

    lea rdi, [rel struct_time_type]
    call structseq_init_type
    lea rax, [rel struct_time_type]
    inc qword [rax + PyObject.ob_refcnt]
    push rax
    lea rdi, [rel tm_struct_time]
    call str_from_cstr_heap
    push rax
    mov rdi, r12
    mov rsi, rax
    mov rdx, [rsp + 8]
    call dict_set
    pop rdi
    call obj_decref
    pop rdi
    call obj_decref

    ; --- the integer-nanosecond clocks, and _STRUCT_TM_ITEMS ---
    ;
    ; _strptime.py's last line is
    ; `time.struct_time(tt[:time._STRUCT_TM_ITEMS])`, so the absence of that
    ; one number was every strptime call in the stdlib.  struct_time already
    ; declared n_fields = 11; the module simply never published it.
    TIME_ADD_FUNC time_time_ns_func,         tm_time_ns
    TIME_ADD_FUNC time_monotonic_ns_func,    tm_monotonic_ns
    TIME_ADD_FUNC time_perf_counter_ns_func, tm_perf_counter_ns
    TIME_ADD_FUNC time_process_time_ns_func, tm_process_time_ns

    ; The clock a caller names, rather than one of the five above.
    TIME_ADD_FUNC time_clock_gettime_func,    tm_clock_gettime
    TIME_ADD_FUNC time_clock_gettime_ns_func, tm_clock_gettime_ns
    TIME_ADD_FUNC time_clock_getres_func,     tm_clock_getres
    TIME_ADD_FUNC time_thread_time_func,      tm_thread_time
    TIME_ADD_FUNC time_thread_time_ns_func,   tm_thread_time_ns
    TIME_ADD_FUNC time_tzset_func,            tm_tzset
    TIME_ADD_FUNC time_strptime_func,         tm_strptime

    ; The clock ids those four take.  CLOCK_TAI is 11 and there is no 10;
    ; the gap is Linux's, not a transcription slip.  The two _COARSE ids are
    ; deliberately not published: CPython does not export them either, and a
    ; name this module has and CPython's does not is as much a divergence as
    ; one it lacks.
    mov edi, CLOCK_REALTIME
    lea rsi, [rel tm_n_CLOCK_REALTIME]
    call tm_add_int
    mov edi, CLOCK_MONOTONIC
    lea rsi, [rel tm_n_CLOCK_MONOTONIC]
    call tm_add_int
    mov edi, CLOCK_PROCESS_CPUTIME_ID
    lea rsi, [rel tm_n_CLOCK_PROCESS_CPUTIME_ID]
    call tm_add_int
    mov edi, CLOCK_THREAD_CPUTIME_ID
    lea rsi, [rel tm_n_CLOCK_THREAD_CPUTIME_ID]
    call tm_add_int
    mov edi, CLOCK_MONOTONIC_RAW
    lea rsi, [rel tm_n_CLOCK_MONOTONIC_RAW]
    call tm_add_int
    mov edi, CLOCK_BOOTTIME
    lea rsi, [rel tm_n_CLOCK_BOOTTIME]
    call tm_add_int
    mov edi, CLOCK_TAI
    lea rsi, [rel tm_n_CLOCK_TAI]
    call tm_add_int

    mov edi, 11
    lea rsi, [rel tm_struct_tm_items]
    call tm_add_int

    ; Add time and sleep
    lea rdi, [rel time_time_func]
    lea rsi, [rel tm_time_name]
    call builtin_func_new
    push rax
    lea rdi, [rel tm_time_name]
    call str_from_cstr_heap
    push rax
    mov rdi, r12
    mov rsi, rax
    mov rdx, [rsp + 8]
    call dict_set
    pop rdi
    call obj_decref
    pop rdi
    call obj_decref

    lea rdi, [rel time_sleep_func]
    lea rsi, [rel tm_sleep]
    call builtin_func_new
    push rax
    lea rdi, [rel tm_sleep]
    call str_from_cstr_heap
    push rax
    mov rdi, r12
    mov rsi, rax
    mov rdx, [rsp + 8]
    call dict_set
    pop rdi
    call obj_decref
    pop rdi
    call obj_decref

    ; Add monotonic function
    lea rdi, [rel time_monotonic_func]
    lea rsi, [rel tm_monotonic]
    call builtin_func_new
    push rax
    lea rdi, [rel tm_monotonic]
    call str_from_cstr_heap
    push rax
    mov rdi, r12
    mov rsi, rax
    mov rdx, [rsp + 8]
    call dict_set
    pop rdi
    call obj_decref
    pop rdi
    call obj_decref

    ; Add perf_counter function
    lea rdi, [rel time_perf_counter_func]
    lea rsi, [rel tm_perf_counter]
    call builtin_func_new
    push rax
    lea rdi, [rel tm_perf_counter]
    call str_from_cstr_heap
    push rax
    mov rdi, r12
    mov rsi, rax
    mov rdx, [rsp + 8]
    call dict_set
    pop rdi
    call obj_decref
    pop rdi
    call obj_decref

    ; Create module object
    lea rdi, [rel tm_time]
    call str_from_cstr_heap
    push rax                ; save name for DECREF
    mov rdi, rax
    mov rsi, r12
    call module_new
    mov rbx, rax            ; save module
    pop rdi                 ; DECREF name (module_new INCREF'd)
    call obj_decref
    mov rdi, r12            ; DECREF dict (module_new INCREF'd)
    call obj_decref
    mov rax, rbx            ; return module

    pop r12
    pop rbx
    leave
    ret
END_FUNC time_module_create

;; ============================================================================
;; Data
;; ============================================================================
section .rodata
align 8
tm_1e9: dq 0x41cdcd6500000000     ; 1e9 as IEEE 754 double
; The int64 range a nanosecond count has to fit, as doubles.  (double)INT64_MAX
; rounds up to 2^63, so the positive test is >= rather than >; the only value
; that separates the two is 2^63 nanoseconds exactly, and refusing it is the
; safe side of a cast that would otherwise be undefined.
tm_i64_max: dq 0x43e0000000000000   ; 2^63
tm_i64_min: dq 0xc3e0000000000000   ; -2^63

tm_time:         db "time", 0
tm_process_time: db "process_time", 0
tm_time_name: db "time", 0
tm_sleep: db "sleep", 0
tm_monotonic:    db "monotonic", 0
tm_perf_counter: db "perf_counter", 0
tm_localtime:    db "localtime", 0
tm_gmtime:       db "gmtime", 0
tm_mktime:       db "mktime", 0
tm_strftime:     db "strftime", 0
tm_asctime:      db "asctime", 0
tm_ctime:        db "ctime", 0
tm_tzname:       db "tzname", 0
tm_timezone:     db "timezone", 0
tm_altzone:      db "altzone", 0
tm_daylight:     db "daylight", 0
tm_struct_time:  db "struct_time", 0
tm_clock_gettime:    db "clock_gettime", 0
tm_clock_gettime_ns: db "clock_gettime_ns", 0
tm_clock_getres:     db "clock_getres", 0
tm_thread_time:      db "thread_time", 0
tm_thread_time_ns:   db "thread_time_ns", 0
tm_tzset:            db "tzset", 0
tm_strptime:         db "strptime", 0
tm_n_CLOCK_REALTIME:           db "CLOCK_REALTIME", 0
tm_n_CLOCK_MONOTONIC:          db "CLOCK_MONOTONIC", 0
tm_n_CLOCK_PROCESS_CPUTIME_ID: db "CLOCK_PROCESS_CPUTIME_ID", 0
tm_n_CLOCK_THREAD_CPUTIME_ID:  db "CLOCK_THREAD_CPUTIME_ID", 0
tm_n_CLOCK_MONOTONIC_RAW:      db "CLOCK_MONOTONIC_RAW", 0
tm_n_CLOCK_BOOTTIME:           db "CLOCK_BOOTTIME", 0
tm_n_CLOCK_TAI:                db "CLOCK_TAI", 0
tm_time_ns:         db "time_ns", 0
tm_monotonic_ns:    db "monotonic_ns", 0
tm_perf_counter_ns: db "perf_counter_ns", 0
tm_process_time_ns: db "process_time_ns", 0
tm_struct_tm_items: db "_STRUCT_TM_ITEMS", 0

; --- get_clock_info ---
;
; One row per clock: the name asked for, the implementation string CPython
; reports for it, and whether it is monotonic and whether it is adjustable.
; The names of the first four are the ones already spelled for the functions
; that read those clocks, so only thread_time needs a string of its own.
TCI_NAME     equ 0
TCI_IMPL     equ 8
TCI_MONO     equ 16
TCI_ADJ      equ 24
TCI_ROW_SIZE equ 32

tci_n_thread_time: db "thread_time", 0
tci_i_realtime:    db "clock_gettime(CLOCK_REALTIME)", 0
tci_i_monotonic:   db "clock_gettime(CLOCK_MONOTONIC)", 0
tci_i_process:     db "clock_gettime(CLOCK_PROCESS_CPUTIME_ID)", 0
tci_i_thread:      db "clock_gettime(CLOCK_THREAD_CPUTIME_ID)", 0
tci_f_impl:        db "implementation", 0
tci_f_mono:        db "monotonic", 0
tci_f_adj:         db "adjustable", 0
tci_f_res:         db "resolution", 0
tci_get_clock_info: db "get_clock_info", 0

align 8
tci_resolution: dq 0x3E112E0BE826D695    ; 1e-09
tci_table:
    dq tm_time,           tci_i_realtime,  0, 1
    dq tm_monotonic,      tci_i_monotonic, 1, 0
    dq tm_perf_counter,   tci_i_monotonic, 1, 0
    dq tm_process_time,   tci_i_process,   1, 0
    dq tci_n_thread_time, tci_i_thread,    1, 0
    dq 0, 0, 0, 0


; --- struct_time ---
st_name: db "time.struct_time", 0
st_f0: db "tm_year", 0
st_f1: db "tm_mon", 0
st_f2: db "tm_mday", 0
st_f3: db "tm_hour", 0
st_f4: db "tm_min", 0
st_f5: db "tm_sec", 0
st_f6: db "tm_wday", 0
st_f7: db "tm_yday", 0
st_f8: db "tm_isdst", 0
st_f9: db "tm_zone", 0
st_f10: db "tm_gmtoff", 0
align 8
st_fields:
    dq st_f0, 0
    dq st_f1, 1
    dq st_f2, 2
    dq st_f3, 3
    dq st_f4, 4
    dq st_f5, 5
    dq st_f6, 6
    dq st_f7, 7
    dq st_f8, 8
    dq st_f9, 9
    dq st_f10, 10
align 8
st_desc:
    dq 9                    ; n_in_sequence: the nine a tuple sees
    dq 11                   ; n_fields: plus tm_zone and tm_gmtoff by name
    dq st_fields

section .data
align 8
global struct_time_type
struct_time_type:
    dq 1                        ; ob_refcnt (immortal)
    dq type_type                ; ob_type
    dq st_name                  ; tp_name
    ; The header plus the named-ONLY tail: two of the eleven fields are not
    ; in the sequence, and the other nine live in ob_item.  This has to move
    ; with st_desc, or the last field is written past the end.
    dq PyTupleObject_size + 2*8 ; tp_basicsize
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
    dq st_desc                  ; STRUCTSEQ_DESC

section .text

;; ============================================================================
;; struct tm, as libc lays it out on x86-64 Linux.  localtime_r and gmtime_r
;; fill one; mktime and strftime read one.
;; ============================================================================
TM_SEC    equ 0
TM_MIN    equ 4
TM_HOUR   equ 8
TM_MDAY   equ 12
TM_MON    equ 16
TM_YEAR   equ 20
TM_WDAY   equ 24
TM_YDAY   equ 28
TM_ISDST  equ 32
TM_GMTOFF equ 40
TM_ZONE   equ 48
TM_SIZE   equ 56

;; ============================================================================
;; time_fill_struct(rdi = a struct tm) -> rax = a struct_time, or 0
;;
;; CPython's field order is NOT libc's: the tuple is
;; (year, mon, mday, hour, min, sec, wday, yday, isdst), with the year offset
;; by 1900, the month 1-based, and Monday as weekday 0 where libc has Sunday.
;; ============================================================================
TFS_TM    equ 8
TFS_OBJ   equ 16
TFS_FRAME equ 40            ; + 1 push = 48, 16-aligned
DEF_FUNC_LOCAL time_fill_struct, TFS_FRAME
    push rbx
    mov [rbp - TFS_TM], rdi
    lea rdi, [rel struct_time_type]
    call structseq_new
    test rax, rax
    jz .tfs_fail
    mov [rbp - TFS_OBJ], rax

    mov rdi, [rbp - TFS_TM]
    mov eax, [rdi + TM_YEAR]
    add eax, 1900
    movsxd rdi, eax
    call int_from_i64
    V_PACK rax, rdx
    mov rdx, rax
    mov rdi, [rbp - TFS_OBJ]
    xor esi, esi
    call structseq_set

    TIME_FIELD 1, TM_MON, 1
    TIME_FIELD 2, TM_MDAY, 0
    TIME_FIELD 3, TM_HOUR, 0
    TIME_FIELD 4, TM_MIN, 0
    TIME_FIELD 5, TM_SEC, 0

    ; Monday is 0 in Python and 1 in libc, where Sunday is 0.
    mov rdi, [rbp - TFS_TM]
    mov eax, [rdi + TM_WDAY]
    add eax, 6
    cdq
    mov ecx, 7
    idiv ecx
    movsxd rdi, edx
    call int_from_i64
    V_PACK rax, rdx
    mov rdx, rax
    mov rdi, [rbp - TFS_OBJ]
    mov esi, 6
    call structseq_set

    TIME_FIELD 7, TM_YDAY, 1
    TIME_FIELD 8, TM_ISDST, 0

    ; The two reachable only by name.
    mov rdi, [rbp - TFS_TM]
    mov rdi, [rdi + TM_ZONE]
    test rdi, rdi
    jz .tfs_no_zone
    call str_from_cstr_heap
    jmp .tfs_zone_done
.tfs_no_zone:
    LOAD_NONE rax
    INCREF rax
.tfs_zone_done:
    ; A pointer IS its own Value, so both arms here need no packing.
    mov rdx, rax
    mov rdi, [rbp - TFS_OBJ]
    mov esi, 9
    call structseq_set

    mov rdi, [rbp - TFS_TM]
    mov rdi, [rdi + TM_GMTOFF]
    call int_from_i64
    V_PACK rax, rdx
    mov rdx, rax
    mov rdi, [rbp - TFS_OBJ]
    mov esi, 10
    call structseq_set

    mov rax, [rbp - TFS_OBJ]
    pop rbx
    leave
    ret
.tfs_fail:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC time_fill_struct

;; ============================================================================
;; time_read_struct(rdi = a 9-or-more sequence, rsi = a struct tm to fill)
;;   -> eax = 1, or 0 with the exception pending
;; The inverse of the above, for mktime and strftime.
;; ============================================================================
TRS_SEQ   equ 8
TRS_TM    equ 16
TRS_I     equ 24
TRS_NAME  equ 32
TRS_FRAME equ 56            ; + 1 push = 64, 16-aligned
DEF_FUNC_LOCAL time_read_struct, TRS_FRAME
    push rbx
    mov [rbp - TRS_SEQ], rdi
    mov [rbp - TRS_TM], rsi
    mov [rbp - TRS_NAME], rdx
    mov rbx, rsi

    ; Zero it: tm_zone and tm_gmtoff are not in the sequence, and libc reads
    ; whatever is there.
    xor ecx, ecx
.trs_zero:
    cmp ecx, TM_SIZE
    jge .trs_zeroed
    mov qword [rbx + rcx], 0
    add ecx, 8
    jmp .trs_zero
.trs_zeroed:

    V_TEST_PTR rdi, rax
    ja .trs_bad
    test rdi, rdi
    jz .trs_bad
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel tuple_type]
    cmp rax, rcx
    je .trs_have
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_TUPLE_SUBCLASS
    jz .trs_bad
.trs_have:
    cmp qword [rdi + PyTupleObject.ob_size], 9
    jl .trs_short

    TIME_READ 0, TM_YEAR, -1900
    TIME_READ 1, TM_MON, -1
    TIME_READ 2, TM_MDAY, 0
    TIME_READ 3, TM_HOUR, 0
    TIME_READ 4, TM_MIN, 0
    TIME_READ 5, TM_SEC, 0
    TIME_READ 7, TM_YDAY, -1
    TIME_READ 8, TM_ISDST, 0

    ; Monday-0 back to Sunday-0.
    mov rax, [rbp - TRS_SEQ]
    mov rax, [rax + PyTupleObject.ob_item]
    mov rdi, [rax + 6*8]
    V_UNPACK rdi, rdx
    call obj_as_index
    inc rax
    cdq
    mov ecx, 7
    idiv ecx
    mov [rbx + TM_WDAY], edx

    mov eax, 1
    pop rbx
    leave
    ret
.trs_short:
    pop rbx
    ; CPython names the caller: "strftime(): illegal time tuple argument".
    ; time_read_struct is shared, so the name comes in as an argument.
    mov rdi, [rbp - TRS_NAME]
    call time_raise_bad_tuple
.trs_bad:
    pop rbx
    RAISE exc_TypeError_type, "Tuple or struct_time argument required"
END_FUNC time_read_struct

;; ============================================================================
;; time.localtime([secs]) and time.gmtime([secs])
;; ============================================================================
TLT_TM    equ 64             ; a struct tm, 56 bytes
TLT_SECS  equ 72
TLT_FRAME equ 80            ; + 0 pushes = 80
%macro DEF_TIME_CONVERT 2   ; %1 = the exposed name, %2 = the libc call
DEF_FUNC time_%1_func, TLT_FRAME
    call time_seconds_arg
    mov [rbp - TLT_SECS], rax
    lea rdi, [rbp - TLT_SECS]
    lea rsi, [rbp - TLT_TM]
    and rsp, -16                ; glibc uses aligned SSE
    call %2 wrt ..plt
    test rax, rax
    jz %%failed
    lea rdi, [rbp - TLT_TM]
    call time_fill_struct
    test rax, rax
    jz %%failed
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret
%%failed:
    RAISE exc_OverflowError_type, "timestamp out of range for platform time_t"
END_FUNC time_%1_func
%endmacro
DEF_TIME_CONVERT localtime, localtime_r
DEF_TIME_CONVERT gmtime,    gmtime_r

;; time_seconds_arg -- the optional first argument, truncated to whole
;; seconds, defaulting to now.  rdi = args, rsi = nargs on entry.
TSA_FRAME equ 32            ; + 0 pushes = 32
DEF_FUNC_LOCAL time_seconds_arg, TSA_FRAME
    test rsi, rsi
    jz .tsa_now
    mov rdi, [rdi]
    LOAD_NONE rax
    cmp rdi, rax
    je .tsa_now
    V_IS_FLOAT rdi, rax
    ja .tsa_int
    V_TO_F64 rdi
    movq xmm0, rdi
    cvttsd2si rax, xmm0
    leave
    ret
.tsa_int:
    V_UNPACK rdi, rdx
    call obj_as_index
    leave
    ret
.tsa_now:
    ; clock_gettime(CLOCK_REALTIME, &ts); only the seconds are wanted.
    mov eax, 228
    mov edi, CLOCK_REALTIME
    lea rsi, [rbp - TSA_FRAME]
    syscall
    mov rax, [rbp - TSA_FRAME]
    leave
    ret
END_FUNC time_seconds_arg

;; ============================================================================
;; time.mktime(t) -> the seconds since the epoch, as a float
;; ============================================================================
TMK_TM    equ 64
TMK_FRAME equ 80            ; + 0 pushes = 80
DEF_FUNC time_mktime_func, TMK_FRAME
    test rsi, rsi
    jz .tmk_args
    mov rdi, [rdi]
    lea rsi, [rbp - TMK_TM]
    CSTRING rdx, "mktime"
    call time_read_struct
    test eax, eax
    jz .tmk_failed
    ; mktime interprets tm_isdst < 0 as "work it out", which is what CPython
    ; passes through.
    lea rdi, [rbp - TMK_TM]
    and rsp, -16                ; glibc uses aligned SSE
    call mktime wrt ..plt
    cmp rax, -1
    je .tmk_range
    cvtsi2sd xmm0, rax
    call float_from_f64
    leave
    V_PACK rax, rdx
    ret
.tmk_range:
    RAISE exc_OverflowError_type, "mktime argument out of range"
.tmk_failed:
    xor eax, eax
    leave
    ret
.tmk_args:
    RAISE exc_TypeError_type, "mktime() takes exactly one argument"
END_FUNC time_mktime_func

;; ============================================================================
;; time.strftime(format[, t]) -> str
;; ============================================================================
TSF_TM    equ 64
TSF_BUF   equ 72
TSF_FMT   equ 80
TSF_FRAME equ 96            ; + 0 pushes = 96
STRFTIME_BUF equ 4096
DEF_FUNC time_strftime_func, TSF_FRAME
    test rsi, rsi
    jz .tsf_args
    push rdi
    push rsi
    mov rdi, [rdi]
    V_TEST_PTR rdi, rax
    ja .tsf_badfmt
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel str_type]
    cmp rax, rcx
    jne .tsf_badfmt
    lea rax, [rdi + PyStrObject.data]
    mov [rbp - TSF_FMT], rax
    pop rsi
    pop rdi

    cmp rsi, 2
    jl .tsf_now
    mov rdi, [rdi + 8]
    lea rsi, [rbp - TSF_TM]
    CSTRING rdx, "strftime"
    call time_read_struct
    test eax, eax
    jz .tsf_failed
    jmp .tsf_have_tm
.tsf_now:
    ; No time given: localtime(now), as CPython does.
    xor esi, esi
    call time_seconds_arg
    mov [rbp - TSF_BUF], rax
    lea rdi, [rbp - TSF_BUF]
    lea rsi, [rbp - TSF_TM]
    and rsp, -16                ; glibc uses aligned SSE
    call localtime_r wrt ..plt
    test rax, rax
    jz .tsf_failed

.tsf_have_tm:
    mov edi, STRFTIME_BUF
    call ap_malloc
    test rax, rax
    jz .tsf_failed
    mov [rbp - TSF_BUF], rax
    mov rdi, rax
    mov esi, STRFTIME_BUF
    mov rdx, [rbp - TSF_FMT]
    lea rcx, [rbp - TSF_TM]
    and rsp, -16                ; glibc uses aligned SSE
    call strftime wrt ..plt
    mov rdi, [rbp - TSF_BUF]
    mov rsi, rax
    call str_new_heap
    push rax
    sub rsp, 8
    mov rdi, [rbp - TSF_BUF]
    call ap_free
    add rsp, 8
    pop rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret

.tsf_badfmt:
    pop rsi                     ; nargs
    pop rdi                     ; args -- the two pushes are gone now
    mov rsi, [rdi]              ; args[0], the format
    CSTRING rdi, `strftime() argument 1 must be str, not \x01`
    extern raise_type_error_with_name
    call raise_type_error_with_name
.tsf_failed:
    xor eax, eax
    leave
    ret
.tsf_args:
    RAISE exc_TypeError_type, "strftime() takes at least 1 argument"
END_FUNC time_strftime_func

;; ============================================================================
;; time.asctime([t]) and time.ctime([secs])
;;
;; Both are strftime with CPython's fixed format; ctime converts first.
;; ============================================================================
TAC_TM    equ 64
TAC_SECS  equ 72
TAC_BUF   equ 80
TAC_FRAME equ 96            ; + 0 pushes = 96
DEF_FUNC time_asctime_func, TAC_FRAME
    test rsi, rsi
    jz .tac_now
    mov rdi, [rdi]
    LOAD_NONE rax
    cmp rdi, rax
    je .tac_now
    lea rsi, [rbp - TAC_TM]
    CSTRING rdx, "asctime"
    call time_read_struct
    test eax, eax
    jz .tac_failed
    jmp .tac_format
.tac_now:
    xor esi, esi
    call time_seconds_arg
    mov [rbp - TAC_SECS], rax
    lea rdi, [rbp - TAC_SECS]
    lea rsi, [rbp - TAC_TM]
    and rsp, -16                ; glibc uses aligned SSE
    call localtime_r wrt ..plt
    test rax, rax
    jz .tac_failed
.tac_format:
    mov edi, 128
    call ap_malloc
    test rax, rax
    jz .tac_failed
    mov [rbp - TAC_BUF], rax
    mov rdi, rax
    mov esi, 128
    lea rdx, [rel tm_asctime_fmt]
    lea rcx, [rbp - TAC_TM]
    and rsp, -16                ; glibc uses aligned SSE
    call strftime wrt ..plt
    mov rdi, [rbp - TAC_BUF]
    mov rsi, rax
    call str_new_heap
    push rax
    sub rsp, 8
    mov rdi, [rbp - TAC_BUF]
    call ap_free
    add rsp, 8
    pop rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
.tac_failed:
    xor eax, eax
    leave
    ret
END_FUNC time_asctime_func

DEF_FUNC time_ctime_func, TAC_FRAME
    call time_seconds_arg
    mov [rbp - TAC_SECS], rax
    lea rdi, [rbp - TAC_SECS]
    lea rsi, [rbp - TAC_TM]
    and rsp, -16                ; glibc uses aligned SSE
    call localtime_r wrt ..plt
    test rax, rax
    jz .tct_failed
    mov edi, 128
    call ap_malloc
    test rax, rax
    jz .tct_failed
    mov [rbp - TAC_BUF], rax
    mov rdi, rax
    mov esi, 128
    lea rdx, [rel tm_asctime_fmt]
    lea rcx, [rbp - TAC_TM]
    and rsp, -16                ; glibc uses aligned SSE
    call strftime wrt ..plt
    mov rdi, [rbp - TAC_BUF]
    mov rsi, rax
    call str_new_heap
    push rax
    sub rsp, 8
    mov rdi, [rbp - TAC_BUF]
    call ap_free
    add rsp, 8
    pop rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
.tct_failed:
    xor eax, eax
    leave
    ret
END_FUNC time_ctime_func

section .rodata
; CPython's asctime format: "Sun Jun 20 23:21:05 1993", with the day of the
; month space-padded rather than zero-padded.
tm_asctime_fmt: db "%a %b %e %H:%M:%S %Y", 0


section .text

;; time_raise_bad_tuple(rdi = the caller's name) -- does not return
TRB_NAME  equ 8
TRB_BUF   equ 176
TRB_FRAME equ 176           ; + 0 pushes = 176, 16-aligned
DEF_FUNC_LOCAL time_raise_bad_tuple, TRB_FRAME
    mov [rbp - TRB_NAME], rdi
    lea rdi, [rbp - TRB_BUF]
    mov rsi, [rbp - TRB_NAME]
    extern rbt_append_cstr
    call rbt_append_cstr
    mov rdi, rax
    CSTRING rsi, "(): illegal time tuple argument"
    call rbt_append_cstr
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rbp - TRB_BUF]
    call raise_exception
END_FUNC time_raise_bad_tuple
