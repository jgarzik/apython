; gcmod.asm - the `gc` module
;
; There was no gc module at all, and gc_collect_gen had three callers, every
; one of them inside gc.asm.  Nothing else in the tree even declared it, so
; there was no way to ask for a collection -- and gc.collect() is what a test
; for a reference cycle is written around.
;
; What is here is the part of CPython's gc that answers about this collector:
; collect, enable/disable/isenabled, the counts and the thresholds, the two
; lists, get_objects, is_tracked, get_referents and the debug flags.
;
; get_objects is a walk of the three generation lists, which are circular and
; doubly linked with static sentinels -- a header here once claimed the
; collector kept no list it could hand back, which was never true.  What is
; still absent is get_referrers, which needs a reverse edge nothing records,
; and freeze/unfreeze and get_stats, which are about machinery this collector
; does not have.

%include "macros.inc"
%include "object.inc"

extern eval_exception_unwind
extern dict_new
extern dict_set
extern obj_decref
extern str_from_cstr_heap
extern builtin_func_new
extern list_new
extern tuple_new
extern int_from_i64
extern obj_as_index
extern none_singleton
extern bool_true
extern bool_false
extern raise_exception
extern exc_TypeError_type
extern exc_ValueError_type

extern gc_collect_gen
extern gc_walk_generation
extern gc_stat_counters
extern gc_enabled
extern gc_debug
extern gc_garbage_list
extern list_append
extern obj_incref
extern obj_dealloc
extern gc_gen0_count
extern gc_gen1_collections
extern gc_gen2_collections
extern gc_gen0_threshold
extern gc_gen1_threshold
extern gc_gen2_threshold

section .text

;; ============================================================================
;; gc_mod_collect(args, nargs) -> the number of unreachable objects found
;;   collect(generation=2)
;; ============================================================================
GMC_GEN   equ 8
GMCF_FRAME equ 16           ; + 0 pushes = 16

DEF_FUNC gc_mod_collect, GMCF_FRAME
    cmp rsi, 1
    ja .gmc_args
    mov qword [rbp - GMC_GEN], 2    ; the whole of it, as CPython's default is
    test rsi, rsi
    jz .gmc_have_gen
    mov rdi, [rdi]
    V_UNPACK rdi, rdx
    call obj_as_index
    ERR_M1 .idx_fail
    test rax, rax
    jl .gmc_range
    cmp rax, 2
    jg .gmc_range
    mov [rbp - GMC_GEN], rax
.gmc_have_gen:
    mov edi, [rbp - GMC_GEN]
    call gc_collect_gen
    mov rdi, rax
    call int_from_i64
    leave
    V_PACK rax, rdx
    ret

.gmc_args:
    RAISE exc_TypeError_type, "collect() takes at most 1 argument"
.gmc_range:
    RAISE exc_ValueError_type, "invalid generation"
.idx_fail:                      ; not an index: the exception is pending
    xor eax, eax
    leave
    ret
END_FUNC gc_mod_collect

;; ============================================================================
;; enable / disable / isenabled
;; ============================================================================
DEF_FUNC gc_mod_enable
    mov qword [rel gc_enabled], 1
    LOAD_NONE rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
END_FUNC gc_mod_enable

DEF_FUNC gc_mod_disable
    mov qword [rel gc_enabled], 0
    LOAD_NONE rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
END_FUNC gc_mod_disable

DEF_FUNC gc_mod_isenabled
    cmp qword [rel gc_enabled], 0
    je .gmi_false
    RET_TRUE
    leave
    V_PACK rax, rdx
    ret
.gmi_false:
    RET_FALSE
    leave
    V_PACK rax, rdx
    ret
END_FUNC gc_mod_isenabled

;; ============================================================================
;; get_count() / get_threshold() -> a 3-tuple each
;;
;; gm_three(rdi = the first, rsi = the second, rdx = the third) -> a tuple
;; ============================================================================
GM3_A     equ 8
GM3_B     equ 16
GM3_C     equ 24
GM3_TUP   equ 32
GM3_FRAME equ 48            ; + 0 pushes = 48

DEF_FUNC_LOCAL gm_three, GM3_FRAME
    mov [rbp - GM3_A], rdi
    mov [rbp - GM3_B], rsi
    mov [rbp - GM3_C], rdx
    mov edi, 3
    call tuple_new
    test rax, rax
    jz .gm3_out
    mov [rbp - GM3_TUP], rax

    mov rdi, [rbp - GM3_A]
    call int_from_i64
    V_PACK rax, rdx
    mov rcx, [rbp - GM3_TUP]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov [rcx], rax

    mov rdi, [rbp - GM3_B]
    call int_from_i64
    V_PACK rax, rdx
    mov rcx, [rbp - GM3_TUP]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov [rcx + 8], rax

    mov rdi, [rbp - GM3_C]
    call int_from_i64
    V_PACK rax, rdx
    mov rcx, [rbp - GM3_TUP]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov [rcx + 16], rax

    mov rax, [rbp - GM3_TUP]
.gm3_out:
    leave
    ret
END_FUNC gm_three

; CPython's get_count() is (allocations since the last gen0 pass, gen0
; collections since the last gen1 pass, gen1 collections since the last gen2
; pass) -- only the first is an object count.  The last two were reported
; from a pair of counters nothing ever incremented, so they were always 0;
; the collector's real ones are gc_gen1_collections and gc_gen2_collections,
; which are also what its own thresholds are compared against.
DEF_FUNC gc_mod_get_count
    test rsi, rsi
    jnz .gmgc_args
    mov rdi, [rel gc_gen0_count]
    mov rsi, [rel gc_gen1_collections]
    mov rdx, [rel gc_gen2_collections]
    call gm_three
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
.gmgc_args:
    RAISE exc_TypeError_type, "get_count() takes no arguments"
END_FUNC gc_mod_get_count

DEF_FUNC gc_mod_get_threshold
    test rsi, rsi
    jnz .gmgt_args
    mov rdi, [rel gc_gen0_threshold]
    mov rsi, [rel gc_gen1_threshold]
    mov rdx, [rel gc_gen2_threshold]
    call gm_three
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
.gmgt_args:
    RAISE exc_TypeError_type, "get_threshold() takes no arguments"
END_FUNC gc_mod_get_threshold

;; ============================================================================
;; set_threshold(gen0[, gen1[, gen2]])
;; ============================================================================
GST_ARGS  equ 8
GST_NARGS equ 16
GST_FRAME equ 32            ; + 0 pushes = 32

DEF_FUNC gc_mod_set_threshold, GST_FRAME
    test rsi, rsi
    jz .gst_args
    cmp rsi, 3
    ja .gst_args
    mov [rbp - GST_ARGS], rdi
    mov [rbp - GST_NARGS], rsi

    mov rdi, [rdi]
    V_UNPACK rdi, rdx
    call obj_as_index
    ERR_M1 .idx_fail
    mov [rel gc_gen0_threshold], rax

    cmp qword [rbp - GST_NARGS], 2
    jl .gst_done
    mov rdi, [rbp - GST_ARGS]
    mov rdi, [rdi + 8]
    V_UNPACK rdi, rdx
    call obj_as_index
    ERR_M1 .idx_fail
    mov [rel gc_gen1_threshold], rax

    cmp qword [rbp - GST_NARGS], 3
    jl .gst_done
    mov rdi, [rbp - GST_ARGS]
    mov rdi, [rdi + 16]
    V_UNPACK rdi, rdx
    call obj_as_index
    ERR_M1 .idx_fail
    mov [rel gc_gen2_threshold], rax

.gst_done:
    LOAD_NONE rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
.gst_args:
    RAISE exc_TypeError_type, "set_threshold() takes 1 to 3 arguments"
.idx_fail:                      ; not an index: the exception is pending
    xor eax, eax
    leave
    ret
END_FUNC gc_mod_set_threshold

;; ============================================================================
;; get_objects([generation]) -> a list of every tracked object
;;
;; The three generations are circular doubly-linked lists with static
;; sentinels, so this is a walk; gc_walk_generation does it with the
;; collector's own reentrancy flag raised.  With no argument, or with None,
;; every generation, oldest first -- which is the order CPython's own
;; get_objects builds its list in.
;; ============================================================================
GGO_LIST  equ 8
GGO_GEN   equ 16
GGO_FRAME equ 40            ; + 1 push = 48, 16-aligned

DEF_FUNC gc_mod_get_objects, GGO_FRAME
    push rbx
    cmp rsi, 1
    ja .ggo_args
    mov qword [rbp - GGO_GEN], -1       ; all of them
    test rsi, rsi
    jz .ggo_have_gen
    mov rdi, [rdi]
    LOAD_NONE rax
    cmp rdi, rax
    je .ggo_have_gen
    V_UNPACK rdi, rdx
    call obj_as_index
    ERR_M1_JUMP
    cmp rax, 2
    jg .ggo_range
    mov [rbp - GGO_GEN], rax    ; negative means all of them, as CPython has it
.ggo_have_gen:
    xor edi, edi
    call list_new
    mov [rbp - GGO_LIST], rax

    mov rbx, [rbp - GGO_GEN]
    test rbx, rbx
    jge .ggo_one
    xor ebx, ebx
.ggo_all_loop:
    cmp rbx, 3
    jge .ggo_out
    mov rdi, rbx
    mov rsi, [rbp - GGO_LIST]
    call gc_walk_generation
    inc rbx
    jmp .ggo_all_loop

.ggo_one:
    mov rdi, rbx
    mov rsi, [rbp - GGO_LIST]
    call gc_walk_generation

.ggo_out:
    mov rax, [rbp - GGO_LIST]
    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.ggo_args:
    RAISE exc_TypeError_type, "get_objects() takes at most 1 argument"
.ggo_range:
    RAISE exc_ValueError_type, "generation parameter must be less than the number of available generations (3)"
END_FUNC gc_mod_get_objects

;; ============================================================================
;; get_referrers(*objs) -> everything that refers to any of the arguments
;;
;; No edge is recorded in the other direction, and CPython records none
;; either: it walks every tracked object and asks whether that one points at
;; the argument, which is O(heap) per call and is what this does.  The
;; traverse is the only thing that knows an object's edges, so the walk hangs
;; a filter off the same gm_referents_out hook get_referents uses.
;; ============================================================================
GGF_ARGS  equ 8
GGF_NARGS equ 16
GGF_LIST  equ 24
GGF_ALL   equ 32            ; every tracked object, from gc_walk_generation
GGF_I     equ 40
GGF_FRAME equ 48            ; 40 used + 8 pad = 48, 16-aligned
DEF_FUNC gc_mod_get_referrers, GGF_FRAME
    push rbx
    push r12
    push r13
    push r14                    ; four pushes keep rsp 16-aligned at the calls
    mov [rbp - GGF_ARGS], rdi
    mov [rbp - GGF_NARGS], rsi

    xor edi, edi
    call list_new
    mov [rbp - GGF_LIST], rax
    xor edi, edi
    call list_new
    mov [rbp - GGF_ALL], rax

    ; Every tracked object, in every generation.
    xor ebx, ebx
.ggf_gen_loop:
    cmp rbx, 3
    jge .ggf_have_all
    mov rdi, rbx
    mov rsi, [rbp - GGF_ALL]
    call gc_walk_generation
    inc rbx
    jmp .ggf_gen_loop
.ggf_have_all:

    mov qword [rbp - GGF_I], 0
.ggf_scan:
    mov rax, [rbp - GGF_ALL]
    mov rcx, [rbp - GGF_I]
    cmp rcx, [rax + PyListObject.ob_size]
    jge .ggf_done
    mov rax, [rax + PyListObject.ob_item]
    mov r12, [rax + rcx*8]      ; the candidate referrer
    inc qword [rbp - GGF_I]

    V_TEST_PTR r12, rax
    ja .ggf_scan
    ; The two lists this call made are not answers about anything.
    cmp r12, [rbp - GGF_LIST]
    je .ggf_scan
    cmp r12, [rbp - GGF_ALL]
    je .ggf_scan
    mov rax, [r12 + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_traverse]
    test rax, rax
    jz .ggf_scan

    ; Collect its edges, then look for any of the arguments among them.
    xor edi, edi
    call list_new
    mov r13, rax
    mov rax, [rel gm_referents_out]
    push rax
    mov [rel gm_referents_out], r13
    ; The visit callback goes in r14, which is what VISIT_PTR calls -- and
    ; r14 is where the argument index lives below, so it is reloaded there.
    mov rdi, r12
    lea r14, [rel gm_visit_append]
    mov rax, [r12 + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_traverse]
    call rax
    pop rax
    mov [rel gm_referents_out], rax

    xor r14d, r14d              ; argument index
.ggf_arg_loop:
    cmp r14, [rbp - GGF_NARGS]
    jge .ggf_edges_done
    mov rax, [rbp - GGF_ARGS]
    mov rcx, [rax + r14*8]      ; the argument, as a Value
    xor eax, eax                ; edge index
.ggf_edge_loop:
    cmp rax, [r13 + PyListObject.ob_size]
    jge .ggf_next_arg
    mov rdx, [r13 + PyListObject.ob_item]
    cmp [rdx + rax*8], rcx
    je .ggf_hit
    inc rax
    jmp .ggf_edge_loop
.ggf_next_arg:
    inc r14
    jmp .ggf_arg_loop
.ggf_hit:
    mov rdi, [rbp - GGF_LIST]
    mov rsi, r12
    call list_append
.ggf_edges_done:
    mov rdi, r13
    call obj_decref
    jmp .ggf_scan

.ggf_done:
    mov rdi, [rbp - GGF_ALL]
    call obj_decref
    mov rax, [rbp - GGF_LIST]
    mov edx, TAG_PTR
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret
END_FUNC gc_mod_get_referrers

;; ============================================================================
;; freeze() / unfreeze() / get_freeze_count()
;;
;; CPython's permanent generation: freeze() moves everything tracked into a
;; list the collector never walks, which is what a program does after startup
;; so that a fork's copy-on-write pages are not dirtied by refcount writes on
;; objects that will never be collected anyway.  There is no permanent
;; generation here, and adding one is a collector change rather than a module
;; one -- but the three functions exist and are honest: freeze() moves nothing
;; and says so by leaving the count at zero, which is exactly what a program
;; that calls unfreeze() straight after would see.
;; ============================================================================
DEF_FUNC gc_mod_freeze
    ; A full collection first, which is what CPython's freeze() effectively
    ; leaves behind: everything unreachable is gone, and what is left would
    ; have been the permanent generation's contents.
    mov edi, 2
    extern gc_collect_gen
    call gc_collect_gen
    RET_NONE
    leave
    V_PACK rax, rdx
    ret
END_FUNC gc_mod_freeze

DEF_FUNC gc_mod_unfreeze
    RET_NONE
    leave
    V_PACK rax, rdx
    ret
END_FUNC gc_mod_unfreeze

DEF_FUNC gc_mod_get_freeze_count
    xor eax, eax
    RET_TAG_SMALLINT
    leave
    V_PACK rax, rdx
    ret
END_FUNC gc_mod_get_freeze_count

;; ============================================================================
;; get_stats() -> one dict per generation
;;
;; CPython's three keys, counted per generation: how many collections have run
;; there, how many objects they freed, and how many they could not.  Nothing
;; was counted before, so the collector keeps three counters per generation
;; now and this reads them.
;; ============================================================================
GGS_LIST  equ 8
GGS_DICT  equ 16
GGS_I     equ 24
GGS_FRAME equ 40            ; + 1 push = 48, 16-aligned
DEF_FUNC gc_mod_get_stats, GGS_FRAME
    push rbx
    xor edi, edi
    call list_new
    mov [rbp - GGS_LIST], rax
    mov qword [rbp - GGS_I], 0
.ggs_loop:
    cmp qword [rbp - GGS_I], 3
    jge .ggs_done
    extern dict_new
    call dict_new
    mov [rbp - GGS_DICT], rax
    mov rbx, [rbp - GGS_I]
    imul rbx, 24                ; three counters per generation

    mov rdi, [rbp - GGS_DICT]
    CSTRING rsi, "collections"
    lea rax, [rel gc_stat_counters]
    mov rdx, [rax + rbx]
    call gm_stat_put
    mov rdi, [rbp - GGS_DICT]
    CSTRING rsi, "collected"
    lea rax, [rel gc_stat_counters]
    mov rdx, [rax + rbx + 8]
    call gm_stat_put
    mov rdi, [rbp - GGS_DICT]
    CSTRING rsi, "uncollectable"
    lea rax, [rel gc_stat_counters]
    mov rdx, [rax + rbx + 16]
    call gm_stat_put

    mov rdi, [rbp - GGS_LIST]
    mov rsi, [rbp - GGS_DICT]
    call list_append
    mov rdi, [rbp - GGS_DICT]
    call obj_decref
    inc qword [rbp - GGS_I]
    jmp .ggs_loop
.ggs_done:
    mov rax, [rbp - GGS_LIST]
    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx
    ret
END_FUNC gc_mod_get_stats

;; gm_stat_put(rdi = dict, rsi = key cstr, rdx = an int64)
DEF_FUNC_LOCAL gm_stat_put
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rdx
    mov rdi, rsi
    extern str_from_cstr_heap
    call str_from_cstr_heap
    push rax
    mov rdi, rbx
    mov rsi, rax
    mov rdx, r12
    V_PACK_I64 rdx, rcx
    extern dict_set
    call dict_set
    pop rdi
    call obj_decref
    pop r12
    pop rbx
    leave
    ret
END_FUNC gm_stat_put

;; ============================================================================
;; is_tracked(obj)
;;
;; An immediate -- an int, a float, None -- is not an object at all here, so
;; it is never tracked.  A heap object is tracked when its type asked to be
;; and it is currently in a generation list.
;; ============================================================================
DEF_FUNC gc_mod_is_tracked
    cmp rsi, 1
    jne .git_args
    mov rdi, [rdi]
    V_TEST_PTR rdi, rax
    ja .git_false                       ; an immediate is not an object at all
    mov rax, [rdi + PyObject.ob_type]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_HAVE_GC
    jz .git_false
    GC_SKIP_STATIC_TYPE rdi, rax, .git_false
    cmp qword [rdi - GC_HEAD_SIZE + PyGC_Head.gc_next], 0
    je .git_false
    RET_TRUE
    leave
    V_PACK rax, rdx
    ret
.git_false:
    RET_FALSE
    leave
    V_PACK rax, rdx
    ret
.git_args:
    RAISE exc_TypeError_type, "is_tracked() takes exactly one argument"
END_FUNC gc_mod_is_tracked

;; ============================================================================
;; get_referents(*objs) -> everything the arguments refer to
;;
;; tp_traverse is what the collector itself walks with, so this is the same
;; walk with a different visit callback.  The callback reaches its
;; destination through a file-local global, the way gc_visit_reachable
;; reaches the sentinel it rescues into: the visit ABI is one argument.
;; ============================================================================
section .data
gm_referents_out: dq 0
section .text

DEF_FUNC_LOCAL gm_visit_append, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    mov rdi, [rel gm_referents_out]
    mov rsi, rbx
    call list_append
    pop rbx
    leave
    ret
END_FUNC gm_visit_append

GGR_LIST  equ 8
GGR_ARGS  equ 16
GGR_NARGS equ 24
GGR_SAVED equ 32
GGR_FRAME equ 40            ; + 3 pushes = 64

DEF_FUNC gc_mod_get_referents, GGR_FRAME
    push rbx
    push r12
    ; r14 is the visit callback the VISIT_* macros call through, and it is
    ; CALLEE-SAVED: writing it without saving hands the caller a different
    ; one back.  map_iternext keeps its count there, so
    ; `list(map(gc.get_referents, ...))` returned into a wild address.
    ; get_referrers beside this one saves it; this did not.
    push r14
    mov [rbp - GGR_ARGS], rdi
    mov [rbp - GGR_NARGS], rsi
    xor edi, edi
    call list_new
    mov [rbp - GGR_LIST], rax
    mov rax, [rel gm_referents_out]
    mov [rbp - GGR_SAVED], rax
    mov rax, [rbp - GGR_LIST]
    mov [rel gm_referents_out], rax

    xor ebx, ebx
.ggr_loop:
    cmp rbx, [rbp - GGR_NARGS]
    jge .ggr_done
    mov rax, [rbp - GGR_ARGS]
    mov r12, [rax + rbx*8]
    V_TEST_PTR r12, rax
    ja .ggr_next
    mov rax, [r12 + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_traverse]
    test rax, rax
    jz .ggr_next
    mov rdi, r12
    lea r14, [rel gm_visit_append]
    call rax
.ggr_next:
    inc rbx
    jmp .ggr_loop
.ggr_done:
    mov rax, [rbp - GGR_SAVED]
    mov [rel gm_referents_out], rax
    mov rax, [rbp - GGR_LIST]
    mov edx, TAG_PTR
    pop r14
    pop r12
    pop rbx
    leave
    V_PACK rax, rdx
    ret
END_FUNC gc_mod_get_referents

;; ============================================================================
;; set_debug(flags) / get_debug()
;; ============================================================================
DEF_FUNC gc_mod_set_debug
    cmp rsi, 1
    jne .gsd_args
    mov rdi, [rdi]
    V_UNPACK rdi, rdx
    call obj_as_index
    ERR_M1 .idx_fail
    mov [rel gc_debug], rax
    LOAD_NONE rax
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
.gsd_args:
    RAISE exc_TypeError_type, "set_debug() takes exactly one argument"
.idx_fail:                      ; not an index: the exception is pending
    xor eax, eax
    leave
    ret
END_FUNC gc_mod_set_debug

DEF_FUNC gc_mod_get_debug
    test rsi, rsi
    jnz .ggd_args
    mov rdi, [rel gc_debug]
    call int_from_i64
    leave
    V_PACK rax, rdx
    ret
.ggd_args:
    RAISE exc_TypeError_type, "get_debug() takes no arguments"
END_FUNC gc_mod_get_debug

;; ============================================================================
;; gc_module_create() -> the module dict
;; ============================================================================
GMC_DICT  equ 8
GMC_NAME  equ 16
GMC_MOD   equ 24
GMC_FRAME equ 32            ; + 0 pushes = 32

;; gm_add(rdi = dict, rsi = name cstr, rdx = function)
GMA_FUNC  equ 8
GMA_KEY   equ 16
GMA_FRAME equ 24            ; + 3 pushes = 48

DEF_FUNC_LOCAL gm_add, GMA_FRAME
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, r13
    mov rsi, r12
    call builtin_func_new
    mov [rbp - GMA_FUNC], rax
    mov rdi, r12
    call str_from_cstr_heap
    mov [rbp - GMA_KEY], rax
    mov rdi, rbx
    mov rsi, rax
    mov rdx, [rbp - GMA_FUNC]
    call dict_set
    mov rdi, [rbp - GMA_KEY]
    call obj_decref
    mov rdi, [rbp - GMA_FUNC]
    call obj_decref
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC gm_add

global gc_module_create
DEF_FUNC gc_module_create, GMC_FRAME
    call dict_new
    mov [rbp - GMC_DICT], rax

    mov rdi, rax
    mov rdi, [rbp - GMC_DICT]
    lea rsi, [rel gm_n_collect]
    lea rdx, [rel gc_mod_collect]
    call gm_add
    mov rdi, [rbp - GMC_DICT]
    lea rsi, [rel gm_n_enable]
    lea rdx, [rel gc_mod_enable]
    call gm_add
    mov rdi, [rbp - GMC_DICT]
    lea rsi, [rel gm_n_disable]
    lea rdx, [rel gc_mod_disable]
    call gm_add
    mov rdi, [rbp - GMC_DICT]
    lea rsi, [rel gm_n_isenabled]
    lea rdx, [rel gc_mod_isenabled]
    call gm_add
    mov rdi, [rbp - GMC_DICT]
    lea rsi, [rel gm_n_get_count]
    lea rdx, [rel gc_mod_get_count]
    call gm_add
    mov rdi, [rbp - GMC_DICT]
    lea rsi, [rel gm_n_get_threshold]
    lea rdx, [rel gc_mod_get_threshold]
    call gm_add
    mov rdi, [rbp - GMC_DICT]
    lea rsi, [rel gm_n_set_threshold]
    lea rdx, [rel gc_mod_set_threshold]
    call gm_add
    mov rdi, [rbp - GMC_DICT]
    lea rsi, [rel gm_n_get_objects]
    lea rdx, [rel gc_mod_get_objects]
    call gm_add
    mov rdi, [rbp - GMC_DICT]
    lea rsi, [rel gm_n_is_tracked]
    lea rdx, [rel gc_mod_is_tracked]
    call gm_add
    mov rdi, [rbp - GMC_DICT]
    lea rsi, [rel gm_n_get_referents]
    lea rdx, [rel gc_mod_get_referents]
    call gm_add
    mov rdi, [rbp - GMC_DICT]
    lea rsi, [rel gm_n_get_referrers]
    lea rdx, [rel gc_mod_get_referrers]
    call gm_add
    mov rdi, [rbp - GMC_DICT]
    lea rsi, [rel gm_n_freeze]
    lea rdx, [rel gc_mod_freeze]
    call gm_add
    mov rdi, [rbp - GMC_DICT]
    lea rsi, [rel gm_n_unfreeze]
    lea rdx, [rel gc_mod_unfreeze]
    call gm_add
    mov rdi, [rbp - GMC_DICT]
    lea rsi, [rel gm_n_get_freeze_count]
    lea rdx, [rel gc_mod_get_freeze_count]
    call gm_add
    mov rdi, [rbp - GMC_DICT]
    lea rsi, [rel gm_n_get_stats]
    lea rdx, [rel gc_mod_get_stats]
    call gm_add

    mov rdi, [rbp - GMC_DICT]
    lea rsi, [rel gm_n_set_debug]
    lea rdx, [rel gc_mod_set_debug]
    call gm_add
    mov rdi, [rbp - GMC_DICT]
    lea rsi, [rel gm_n_get_debug]
    lea rdx, [rel gc_mod_get_debug]
    call gm_add

    ; The five DEBUG_* flags, with CPython's values.
    mov rdi, [rbp - GMC_DICT]
    lea rsi, [rel gm_n_d_stats]
    mov edx, GC_DEBUG_STATS
    call gm_add_int
    mov rdi, [rbp - GMC_DICT]
    lea rsi, [rel gm_n_d_coll]
    mov edx, GC_DEBUG_COLLECTABLE
    call gm_add_int
    mov rdi, [rbp - GMC_DICT]
    lea rsi, [rel gm_n_d_uncoll]
    mov edx, GC_DEBUG_UNCOLLECTABLE
    call gm_add_int
    mov rdi, [rbp - GMC_DICT]
    lea rsi, [rel gm_n_d_saveall]
    mov edx, GC_DEBUG_SAVEALL
    call gm_add_int
    mov rdi, [rbp - GMC_DICT]
    lea rsi, [rel gm_n_d_leak]
    mov edx, GC_DEBUG_LEAK
    call gm_add_int

    ; gc.garbage and gc.callbacks: both always empty here.  Nothing is ever
    ; put in garbage, because nothing is declared uncollectable -- a __del__
    ; no longer keeps a cycle alive in CPython either -- and there is no
    ; callback machinery to run.  They exist because code reads them.
    mov rdi, [rbp - GMC_DICT]
    lea rsi, [rel gm_n_garbage]
    call gm_add_empty_list
    ; The collector needs this one by name: DEBUG_SAVEALL puts the unreachable
    ; set in it instead of clearing it.  The module dict owns the reference.
    mov [rel gc_garbage_list], rax
    mov rdi, [rbp - GMC_DICT]
    lea rsi, [rel gm_n_callbacks]
    call gm_add_empty_list

    ; And the module object around it, as every builtin module does.
    lea rdi, [rel gm_n_gc]
    call str_from_cstr_heap
    mov [rbp - GMC_NAME], rax
    mov rdi, rax
    mov rsi, [rbp - GMC_DICT]
    extern module_new
    call module_new
    mov [rbp - GMC_MOD], rax
    mov rdi, [rbp - GMC_NAME]
    call obj_decref             ; module_new took its own
    mov rdi, [rbp - GMC_DICT]
    call obj_decref
    mov rax, [rbp - GMC_MOD]
    leave
    ret
END_FUNC gc_module_create

;; gm_add_empty_list(rdi = dict, rsi = name cstr)
GME_LIST  equ 8
GME_KEY   equ 16
GME_FRAME equ 32            ; + 2 pushes = 48, 16-aligned

DEF_FUNC_LOCAL gm_add_empty_list, GME_FRAME
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    xor edi, edi
    call list_new
    mov [rbp - GME_LIST], rax
    mov rdi, r12
    call str_from_cstr_heap
    mov [rbp - GME_KEY], rax
    mov rdi, rbx
    mov rsi, rax
    mov rdx, [rbp - GME_LIST]
    call dict_set
    mov rdi, [rbp - GME_KEY]
    call obj_decref
    mov rdi, [rbp - GME_LIST]
    call obj_decref
    mov rax, [rbp - GME_LIST]           ; borrowed; the module dict owns it
    pop r12
    pop rbx
    leave
    ret
END_FUNC gm_add_empty_list

;; gm_add_int(rdi = dict, rsi = name cstr, rdx = value)
GMI_KEY   equ 8
GMI_VAL   equ 16
GMI_FRAME equ 32            ; + 2 pushes = 48

DEF_FUNC_LOCAL gm_add_int, GMI_FRAME
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rdx
    call int_from_i64
    V_PACK rax, rdx
    mov [rbp - GMI_VAL], rax
    mov rdi, r12
    call str_from_cstr_heap
    mov [rbp - GMI_KEY], rax
    mov rdi, rbx
    mov rsi, rax
    mov rdx, [rbp - GMI_VAL]
    call dict_set
    mov rdi, [rbp - GMI_KEY]
    call obj_decref
    mov rdi, [rbp - GMI_VAL]
    DECREF_V rdi, rax
    pop r12
    pop rbx
    leave
    ret
END_FUNC gm_add_int

section .rodata
gm_n_collect:       db "collect", 0
gm_n_enable:        db "enable", 0
gm_n_disable:       db "disable", 0
gm_n_isenabled:     db "isenabled", 0
gm_n_get_count:     db "get_count", 0
gm_n_get_threshold: db "get_threshold", 0
gm_n_set_threshold: db "set_threshold", 0
gm_n_garbage:       db "garbage", 0
gm_n_callbacks:     db "callbacks", 0
gm_n_get_objects:   db "get_objects", 0
gm_n_is_tracked:    db "is_tracked", 0
gm_n_get_referents: db "get_referents", 0
gm_n_get_referrers: db "get_referrers", 0
gm_n_freeze:        db "freeze", 0
gm_n_unfreeze:      db "unfreeze", 0
gm_n_get_freeze_count: db "get_freeze_count", 0
gm_n_get_stats:     db "get_stats", 0
gm_n_set_debug:     db "set_debug", 0
gm_n_get_debug:     db "get_debug", 0
gm_n_d_stats:       db "DEBUG_STATS", 0
gm_n_d_coll:        db "DEBUG_COLLECTABLE", 0
gm_n_d_uncoll:      db "DEBUG_UNCOLLECTABLE", 0
gm_n_d_saveall:     db "DEBUG_SAVEALL", 0
gm_n_d_leak:        db "DEBUG_LEAK", 0
gm_n_gc:            db "gc", 0
