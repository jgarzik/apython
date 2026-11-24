; pyo/instance_alloc.asm - allocating an instance, and the builtin-subclass forms
;
; instance_new is where every user-defined class's instance comes from.  A
; class deriving from a builtin needs more than a zeroed body: the base's own
; fields are embedded in the instance, and list and dict want a real backing
; array before any method touches them -- a NULL ob_item is how list marks
; "currently being sorted", so the first append on a fresh subclass instance
; reported "list modified during sort".  int, str and tuple are immutable and
; carry their value inline, so each gets a constructor of its own that fills
; the base portion at allocation time and can be called as `int.__new__(cls,
; v)` without going back through cls.__new__ -- which is how enum builds its
; members, and would otherwise recurse forever.
;
; It came out of class.asm, which held the metatype, the instance, the bound
; method and this, and was over the size a hand-written file in this tree is
; allowed.

%include "macros.inc"
%include "object.inc"

extern object_type
extern exc_TypeError_type
extern raise_exception
extern str_from_cstr_heap
extern type_call
extern dict_get
extern raise_type_error_with_typename
extern raise_type_error_with_name
extern dunder_lookup_owner
extern rbt_append_cstr
extern new_dunder_cstr
extern init_dunder_cstr
extern ap_malloc
extern ap_memcpy
extern gc_alloc
extern gc_track
extern gc_dealloc
extern obj_incref
extern obj_decref
extern obj_dealloc
extern dict_new
extern dict_alloc_tables
extern str_set_length
extern builtin_int_fn
extern builtin_str_fn
extern tuple_type_call
extern int_type
extern tuple_type

global instance_new
global int_sub_new
global str_sub_new
global tuple_sub_fill
global builtin_sub_init_base
global builtin_sub_alloc
global builtin_sub_dealloc

section .text

;; ============================================================================
;; instance_new(PyTypeObject *type) -> PyInstanceObject*
;; Allocate a new instance of the given class type.
;; rdi = type (the class)
;; Returns: new instance with refcnt=1, ob_type=type, inst_dict=new dict
;; ============================================================================
;; ============================================================================
;; builtin_sub_init_base(rdi = instance)
;;
;; Give the embedded base portion of a builtin-container subclass a valid
;; empty state.  instance_new zeroes the body, which is already a correct
;; empty tuple, but list and dict want a real backing array -- a NULL
;; ob_item is how list marks "currently being sorted", so the first
;; l.append() on a fresh subclass instance reported "list modified during
;; sort".
;; ============================================================================

;; ============================================================================
;; int_sub_new(rdi = type, rsi = args, rdx = nargs) -> (rax, rdx) value pair
;;
;; An int, or an instance of an int subclass carrying one.  It is what
;; `int(...)` does for such a type, reachable as a function so that
;; `int.__new__(cls, v)` can build the instance WITHOUT going back through
;; cls.__new__ -- which is how enum makes its members, and would otherwise
;; recurse forever.
;; ============================================================================
ISN_TYPE  equ 8
ISN_VAL   equ 16
ISN_TAG   equ 24
ISN_FRAME equ 32          ; + 2 pushes = 48
DEF_FUNC int_sub_new, ISN_FRAME
    push rbx
    push r12
    mov [rbp - ISN_TYPE], rdi
    mov rdi, rsi
    mov rsi, rdx
    extern builtin_int_fn
    call builtin_int_fn
    test edx, edx
    jz .isn_fail
    mov [rbp - ISN_VAL], rax
    mov [rbp - ISN_TAG], rdx

    ; int itself takes the bare value; a subclass wraps it.
    mov rbx, [rbp - ISN_TYPE]
    lea rcx, [rel int_type]
    cmp rbx, rcx
    je .isn_bare

    mov edi, PyIntSubclassObject_size
    mov rsi, rbx
    call gc_alloc
    mov r12, rax
    mov qword [r12 + PyIntSubclassObject.inst_dict], 0
    mov rax, [rbp - ISN_VAL]
    mov rdx, [rbp - ISN_TAG]
    V_PACK rax, rdx
    mov [r12 + PyIntSubclassObject.int_value], rax   ; the reference transfers
    mov rdi, rbx
    INCREF rdi
    mov rdi, r12
    call gc_track
    mov rax, r12
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

.isn_bare:
    mov rax, [rbp - ISN_VAL]
    mov rdx, [rbp - ISN_TAG]
    pop r12
    pop rbx
    leave
    ret
.isn_fail:
    xor eax, eax
    xor edx, edx
    pop r12
    pop rbx
    leave
    ret
END_FUNC int_sub_new

;; ============================================================================
;; str_sub_new(rdi = subclass type, rsi = args, rdx = nargs) -> instance
;;
;; A str keeps its characters inline, so its instances are variable-size and
;; instance_new -- which allocates exactly tp_basicsize -- cannot make one.
;; A str subclass therefore has to be built here, from the argument, the way
;; str's own constructor would.  Without this the instance was an empty
;; string of the right type, so CustomStr("100") was "".
;;
;; The instance carries a __dict__ at its tail, past the data and its padding,
;; because there is no fixed offset past inline data to put one at.  The extra
;; word is allocated here and tp_dictoffset says TP_DICT_AT_TAIL.
;; ============================================================================
SSN_TYPE  equ 8
SSN_SRC   equ 16
SSN_FRAME equ 32            ; + 2 pushes = 48

DEF_FUNC str_sub_new, SSN_FRAME
    push rbx
    push r12

    mov [rbp - SSN_TYPE], rdi
    mov qword [rbp - SSN_SRC], 0
    test rdx, rdx
    jz .ssn_empty

    ; str(x) of the arguments gives a plain str to copy from.  This called
    ; obj_str on args[0] and ignored the rest, so a str subclass could not be
    ; built from the DECODING form: S(b"abc", "utf-8") came out as the repr
    ; "b'abc'".  builtin_str_fn is the whole of str(), keyword arguments
    ; included, and its one-argument case is the same obj_str.
    mov rdi, rsi
    mov rsi, rdx
    extern builtin_str_fn
    call builtin_str_fn         ; err: .ssn_failed, by the tag below
    V_UNPACK rax, rdx
    test edx, edx
    jz .ssn_failed
    mov [rbp - SSN_SRC], rax
    mov rbx, rax
    mov r12, [rbx + PyStrObject.ob_size]
    jmp .ssn_have_src

.ssn_empty:
    xor ebx, ebx
    xor r12d, r12d

.ssn_have_src:
    ; header + length + 8, matching str_new_heap's padding for the 8-byte
    ; comparisons ap_strcmp does, + 8 more for the tail __dict__ pointer, and
    ; one word per __slots__ entry after that.  A str subclass has nowhere
    ; else to put a slot: its characters are inline, so a fixed offset past
    ; the header lands on them.
    mov rdi, [rbp - SSN_TYPE]
    mov rcx, [rdi + PyTypeObject.tp_tailslots]
    shl rcx, 3
    lea rdi, [r12 + PyStrObject.data + 16]
    add rdi, rcx
    mov rsi, [rbp - SSN_TYPE]
    extern gc_alloc
    call gc_alloc                   ; sets ob_refcnt and ob_type
    mov [rax + PyStrObject.ob_size], r12
    mov qword [rax + PyStrObject.ob_hash], -1
    mov [rax + PyStrObject.ob_length], r12   ; corrected after the copy
    mov qword [rax + PyStrObject.data + r12], 0
    ; The tail __dict__ and every tail slot start empty.  gc_alloc does not
    ; zero, and a slot read before it is written is a Value either way.
    mov rcx, [rbp - SSN_TYPE]
    mov rcx, [rcx + PyTypeObject.tp_tailslots]
    inc rcx                         ; the dict word, then the slots
    lea rdx, [rax + PyStrObject.data + r12 + 8]
.ssn_zero_tail:
    mov qword [rdx], 0
    add rdx, 8
    dec rcx
    jnz .ssn_zero_tail

    test rbx, rbx
    jz .ssn_no_copy
    push rax
    lea rdi, [rax + PyStrObject.data]
    lea rsi, [rbx + PyStrObject.data]
    mov rdx, r12
    call ap_memcpy
    mov rdi, [rsp]
    extern str_set_length
    call str_set_length
    mov rdi, [rbp - SSN_SRC]
    call obj_decref
    pop rax

.ssn_no_copy:
    ; The tail __dict__ is not created here either.  The comment that used to
    ; be here said it had to be, "so that every consumer of LOAD_INST_DICT can
    ; keep reading a NULL as this family has no dict at all" -- and that was
    ; already untrue twice over: .ssn_zero_tail below leaves the word at 0,
    ; instance_setattr's .sa_no_slot arm has created the tail dict on demand
    ; for as long as it has existed, and bytes subclasses ship a NULL one.
    ; SSN_SRC is dead by now -- the copy path decref'd it.
    mov [rbp - SSN_SRC], rax
    mov rax, [rbp - SSN_SRC]

    ; gc_alloc does not INCREF the type it stamps into ob_type.
    push rax
    mov rdi, [rbp - SSN_TYPE]
    call obj_incref
    pop rax
    mov rdi, rax
    push rax
    extern gc_track
    call gc_track
    pop rax
    pop r12
    pop rbx
    leave
    ret

.ssn_failed:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
END_FUNC str_sub_new

;; ============================================================================
;; tuple_sub_fill(rdi = instance, rsi = args, rdx = nargs) -> rax = 0
;; Fails: -1
;;
;; A tuple is immutable and has no __init__, so a subclass cannot be filled
;; after the fact the way list, dict and set are -- the contents have to be
;; put in at construction, which is what tuple.__new__ does.  Without this a
;; tuple subclass was always empty.
;; ============================================================================
TSF_INST  equ 8
TSF_TMP   equ 16
TSF_FRAME equ 40            ; + 3 pushes = 64, 16-aligned

DEF_FUNC tuple_sub_fill, TSF_FRAME
    push rbx
    push r12
    push r13

    mov [rbp - TSF_INST], rdi
    mov qword [rbp - TSF_TMP], 0
    mov qword [rdi + PyTupleObject.ob_hash], -1
    test rdx, rdx
    jz .tsf_done                ; Sub() is the empty tuple

    ; Materialise the argument, so any iterable works.
    push rsi
    lea rdi, [rel tuple_type]
    mov edx, 1
    pop rsi
    call tuple_type_call
    test rax, rax
    jz .tsf_fail                ; not iterable, or iterating it raised
    mov [rbp - TSF_TMP], rax
    mov rbx, rax
    mov r12, [rbx + PyTupleObject.ob_size]
    test r12, r12
    jz .tsf_release

    ; Own copy of the item array: the temporary is about to be released.
    mov rdi, r12
    shl rdi, 3
    call ap_malloc
    mov r13, rax
    mov rcx, [rbp - TSF_INST]
    mov [rcx + PyTupleObject.ob_item], r13
    mov [rcx + PyTupleObject.ob_size], r12

    xor ecx, ecx
.tsf_copy:
    cmp rcx, r12
    jge .tsf_release
    mov rax, [rbx + PyTupleObject.ob_item]
    mov rdi, [rax + rcx * 8]
    mov [r13 + rcx * 8], rdi
    push rcx
    INCREF_V rdi, rax
    pop rcx
    inc rcx
    jmp .tsf_copy

.tsf_release:
    mov rdi, [rbp - TSF_TMP]
    mov qword [rbp - TSF_TMP], 0
    call obj_decref

.tsf_done:
    xor eax, eax
.tsf_out:
    pop r13
    pop r12
    pop rbx
    leave
    ret
.tsf_fail:
    mov rax, -1
    jmp .tsf_out
END_FUNC tuple_sub_fill

DEF_FUNC builtin_sub_init_base, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    mov rax, [rbx + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_flags]

    test rax, TYPE_FLAG_LIST_SUBCLASS
    jnz .bsib_list
    test rax, TYPE_FLAG_DICT_SUBCLASS | TYPE_FLAG_SET_SUBCLASS
    jnz .bsib_dict
    jmp .bsib_done              ; tuple: zeroed is already an empty tuple

.bsib_list:
    mov edi, 4 * 8
    call ap_malloc
    mov [rbx + PyListObject.ob_item], rax
    mov qword [rbx + PyListObject.allocated], 4
    jmp .bsib_done

.bsib_dict:
    ; A dict now owns two arrays, and a set only one -- so let the dict's own
    ; allocator build them rather than hand-rolling a header that would be
    ; missing dk_indices.
    mov rdi, rbx
    mov rax, [rbx + PyObject.ob_type]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_SET_SUBCLASS
    jnz .bsib_set_table
    mov rsi, DICT_INIT_CAP
    extern dict_alloc_tables
    call dict_alloc_tables
    mov qword [rbx + PyDictObject.dk_nentries], 0
    ; A version of its own, from the clock every dict draws on (see
    ; DICT_STAMP_VERSION in dict.asm): a zeroed one is shared by every dict
    ; subclass instance that has not been written to yet.
    extern dict_version_clock
    mov rax, [rel dict_version_clock]
    inc rax
    mov [rel dict_version_clock], rax
    mov [rbx + PyDictObject.dk_version], rax
    jmp .bsib_done

.bsib_set_table:
    ; A set keeps the old single-array layout.
    mov edi, DICT_INIT_CAP * DICT_ENTRY_SIZE
    call ap_malloc
    mov [rbx + PyDictObject.entries], rax
    mov rdi, rax
    mov ecx, DICT_INIT_CAP * DICT_ENTRY_SIZE / 8
    xor eax, eax
    rep stosq
    mov qword [rbx + PyDictObject.capacity], DICT_INIT_CAP
    ; A frozenset caches its hash there, and -1 is the not-yet-computed
    ; sentinel; the zeroed instance would otherwise claim a hash of zero.
    mov qword [rbx + SET_HASH], -1

.bsib_done:
    pop rbx
    leave
    ret
END_FUNC builtin_sub_init_base

;; ============================================================================
;; builtin_sub_alloc(rdi = type) -> rax = a zeroed instance
;;
;; The allocation half of a builtin constructor that has to honour the type it
;; was handed.  float and complex keep their value inline, exactly as int and
;; str do, so a subclass of either cannot come from instance_new -- the base's
;; own constructor builds it, and this is the only part that differs between
;; the base and a subclass.
;;
;; A heaptype always carries TYPE_FLAG_HAVE_GC, so it has to come from
;; gc_alloc and be tracked.  complex itself does not: it owns nothing, and
;; gc_alloc hands back raw + GC_HEAD_SIZE, which obj_dealloc's plain-free path
;; would give ap_free unshifted.  Both branches are here so a caller cannot
;; pick the wrong one.
;;
;; Everything past the header is zeroed, the tail __dict__ slot included: a
;; subclass instance is reachable before its __init__ has run, and the
;; collector reads tp_dictoffset on the way past.
;; ============================================================================
BSA_TYPE  equ 8
BSA_SAVE  equ 16
BSA_FRAME equ 16            ; + 0 pushes = 16

DEF_FUNC builtin_sub_alloc, BSA_FRAME
    mov [rbp - BSA_TYPE], rdi
    mov rsi, [rdi + PyTypeObject.tp_basicsize]
    test qword [rdi + PyTypeObject.tp_flags], TYPE_FLAG_HAVE_GC
    jz .bsa_plain
    mov rdi, rsi
    mov rsi, [rbp - BSA_TYPE]
    call gc_alloc               ; sets ob_refcnt and ob_type itself
    jmp .bsa_zero
.bsa_plain:
    mov rdi, rsi
    call ap_malloc
    mov qword [rax + PyObject.ob_refcnt], 1
    mov rcx, [rbp - BSA_TYPE]
    mov [rax + PyObject.ob_type], rcx

.bsa_zero:
    mov rcx, [rbp - BSA_TYPE]
    mov rcx, [rcx + PyTypeObject.tp_basicsize]
    lea rdx, [rax + PyObject_size]
    sub rcx, PyObject_size
.bsa_zero_loop:
    cmp rcx, 8
    jb .bsa_zeroed
    mov qword [rdx], 0
    add rdx, 8
    sub rcx, 8
    jmp .bsa_zero_loop

.bsa_zeroed:
    ; The instance holds a reference to its type, as every instance does.
    mov rcx, [rbp - BSA_TYPE]
    inc qword [rcx + PyObject.ob_refcnt]
    test qword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_HAVE_GC
    jz .bsa_done
    mov [rbp - BSA_SAVE], rax
    mov rdi, rax
    call gc_track               ; may collect, which is why the body is zeroed
    mov rax, [rbp - BSA_SAVE]
.bsa_done:
    leave
    ret
END_FUNC builtin_sub_alloc

;; ============================================================================
;; descr_alloc(rdi = the class being constructed, rsi = this descriptor's own
;;             static type, edx = that type's instance size) -> rax = the new
;;             instance, ob_refcnt 1 and ob_type set
;;
;; The class a tp_new is called on is NOT always the type it belongs to.
;; buildclass copies a builtin base's tp_new into the subclass and type_call
;; hands it the SUBCLASS, so all three of these built a plain base instance
;; for every subclass ever written: `type(C.__dict__['v'])` on a
;; `class Loud(property)` answered `property`, and Loud.__get__ never ran.
;; The attribute machinery was never at fault -- it falls through to the
;; general __get__ lookup for anything that is not EXACTLY one of the four
;; builtin descriptor types, and what it was handed genuinely was one.
;;
;; builtin_sub_alloc is how every other builtin subclass is built: the class's
;; own tp_basicsize, so __slots__ and a __dict__ have room; everything past
;; the header zeroed, because the collector can see the instance before its
;; fields are filled; and the reference to the class that builtin_sub_dealloc
;; gives back.  The exact type keeps the plain gc_alloc -- it is immortal, and
;; nothing would hand that reference back.
;; ============================================================================
global descr_alloc
DEF_FUNC descr_alloc
    cmp rdi, rsi
    jne .da_subclass
    mov edi, edx                ; rsi already holds the type
    leave
    jmp gc_alloc
.da_subclass:
    extern builtin_sub_alloc
    leave
    jmp builtin_sub_alloc
END_FUNC descr_alloc

;; ============================================================================
;; descr_sub_dealloc(rdi = a subclass instance) -> nothing
;;
;; tp_dealloc for a heaptype subclass of a static base that OWNS things --
;; property, staticmethod and classmethod, the three whose tp_clear is not
;; NULL.  builtin_sub_dealloc, which the subclasses of bytes and bytearray
;; use, frees the object and releases the class and nothing else: those bases
;; keep their data inline and own no references.  These do, and until subclass
;; instances of them existed at all the mismatch could not show -- every
;; `Named(property)` was a plain property, so property_dealloc ran and
;; released the four accessors.  Now the class is honoured, and this releases
;; them.
;;
;; Through the base's tp_clear, which is exactly "release everything held and
;; leave the fields empty" -- the same borrowing instance_dealloc already does
;; for a dict, list, set or tuple subclass's storage.  It zeroes as it goes,
;; so nothing below can release one twice, and instance_dealloc's slot walk
;; starts above them anyway.
;;
;; Then instance_dealloc for the rest of it: __del__, the __slots__, the
;; instance dict, the reference to the class that builtin_sub_alloc took, and
;; the free.
;; ============================================================================
DEF_FUNC descr_sub_dealloc, 8       ; 1 push, so rsp is 16-aligned
    push rbx
    mov rbx, rdi

    mov rax, [rbx + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_clear]
    test rax, rax
    jz .dsd_done
    extern instance_clear
    lea rcx, [rel instance_clear]
    cmp rax, rcx
    je .dsd_done                    ; the generic one holds nothing of its own
    mov rdi, rbx
    call rax
.dsd_done:
    mov rdi, rbx
    pop rbx
    leave
    extern instance_dealloc
    jmp instance_dealloc
END_FUNC descr_sub_dealloc

DEF_FUNC instance_new
    push rbx
    push r12

    mov rbx, rdi                ; rbx = type

    ; Allocate using tp_basicsize (GC-tracked, supports __slots__)
    mov rdi, [rbx + PyTypeObject.tp_basicsize]
    push rdi                    ; save size for zero-fill
    mov rsi, rbx                ; type
    call gc_alloc
    mov r12, rax                ; r12 = instance (ob_refcnt=1, ob_type set)

    ; Zero-fill body past header (handles slot init to TAG_NULL)
    pop rcx                     ; size in bytes
    sub rcx, OBJ_HEADER_SIZE
    jle .skip_zero
    lea rdi, [r12 + OBJ_HEADER_SIZE]
    shr rcx, 3
    xor eax, eax
    rep stosq
.skip_zero:

    ; INCREF type (stored in ob_type)
    mov rdi, rbx
    call obj_incref

    ; The instance dict is NOT created here.  The rep stosq above already left
    ; the slot at 0, and NULL is what every consumer of LOAD_INST_DICT already
    ; handles: instance_setattr creates one on the first store and
    ; obj_generic_attr creates and attaches one on the first read of
    ; __dict__.  int subclasses and bytes subclasses have shipped a NULL slot
    ; from the start.
    ;
    ; It cost a dict_new -- gc_alloc plus two ap_mallocs and two rep stosqs,
    ; nearly 300 bytes -- for every instance, including every one that never
    ; gets an attribute.
.in_no_dict:
    mov rdi, r12
    call gc_track

    mov rax, r12                ; return instance
    pop r12
    pop rbx
    leave
    ret
END_FUNC instance_new

;; ============================================================================
;; builtin_sub_dealloc(PyObject *self)
;; Dealloc for heap-type subclasses of builtin types (bytes, bytearray, etc.)
;; These don't have inst_dict — just DECREF the type and free.
;; ============================================================================
DEF_FUNC builtin_sub_dealloc, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi

    ; Save ob_type before freeing (gc_dealloc reads ob_type)
    push qword [rbx + PyObject.ob_type]

    ; Free the object (may be GC-tracked) — must happen before type DECREF
    mov rdi, rbx
    call gc_dealloc

    ; DECREF ob_type (the class) AFTER freeing the object
    pop rdi
    call obj_decref

    pop rbx
    leave
    ret
END_FUNC builtin_sub_dealloc


;; ============================================================================
;; object_type_call(args, nargs) -> PyObject*
;; object() returns a bare instance of object_type
;; ============================================================================
DEF_FUNC_BARE object_type_call
    ; Create a bare instance with object_type (gc_alloc since HAVE_GC)
    push rbp
    mov rbp, rsp
    ; object() takes nothing.  It accepted anything and dropped it, so
    ; `object(1)` was an object rather than the TypeError CPython raises.
    ; This sits in object's tp_new, so the count is in edx -- rsi is the
    ; argument array.
    test edx, edx
    jnz .otc_no_args
    mov edi, OBJ_HEADER_SIZE
    lea rsi, [rel object_type]
    call gc_alloc

    ; gc_alloc does not INCREF the type it stamps into ob_type, and
    ; instance_dealloc DECREFs it -- so without this the reference count of
    ; object_type itself went down by one for every object() that died.  It
    ; starts at 1, so the FIRST such instance took it to zero and handed
    ; &object_type, a .data address, to ap_free: the heap was corrupted from
    ; then on, and the crash landed in whatever allocated next.
    ; instance_new and slots_new both INCREF here for the same reason.
    push rax
    lea rdi, [rel object_type]
    call obj_incref
    pop rax

    ; Track in GC
    push rax
    mov rdi, rax
    call gc_track
    pop rax
    mov edx, TAG_PTR
    pop rbp
    ret

.otc_no_args:
    RAISE exc_TypeError_type, "object() takes no arguments"
END_FUNC object_type_call

;; ============================================================================
;; type_defines_dunder(rdi = a type, rsi = the name as a C string,
;;                     edx = the PyTypeObject slot that stands for it, or 0)
;;   -> eax = 1 if some class BEFORE object on the MRO defines it, else 0
;;
;; What CPython asks as `type->tp_new != object_new`.  object's own entry is
;; not a definition: it is the default the question is trying to distinguish
;; from, so the walk stops there.
;;
;; A builtin defines its constructor in a SLOT and not in its dict -- bytes
;; has a tp_new and no `__new__` key -- so the slot is asked as well, and a
;; subclass inherits it by pointer.  Passing 0 for it asks the dict alone.
;; ============================================================================
TDD_TYPE  equ 8
TDD_NAME  equ 16
TDD_SLOT  equ 24
TDD_FRAME equ 40            ; + 1 push = 48, 16-aligned
global type_defines_dunder
DEF_FUNC type_defines_dunder, TDD_FRAME
    push rbx
    mov [rbp - TDD_TYPE], rdi
    movsxd rdx, edx
    mov [rbp - TDD_SLOT], rdx
    mov rdi, rsi
    call str_from_cstr_heap
    mov [rbp - TDD_NAME], rax
    mov rbx, [rbp - TDD_TYPE]
.tdd_walk:
    test rbx, rbx
    jz .tdd_no
    lea rax, [rel object_type]
    cmp rbx, rax
    je .tdd_no

    ; The slot first: a builtin defines its constructor there and not in its
    ; dict, and a subclass of one inherits it by pointer.
    mov rdx, [rbp - TDD_SLOT]
    test rdx, rdx
    jz .tdd_dict
    mov rax, [rbx + rdx]
    test rax, rax
    jz .tdd_dict
    lea rcx, [rel object_type_call]
    cmp rax, rcx
    je .tdd_dict
    lea rcx, [rel type_call]
    cmp rax, rcx
    je .tdd_dict
    extern object_method_init
    lea rcx, [rel object_method_init]
    cmp rax, rcx
    je .tdd_dict
    jmp .tdd_yes

.tdd_dict:
    mov rdi, [rbx + PyTypeObject.tp_dict]
    test rdi, rdi
    jz .tdd_next
    mov rsi, [rbp - TDD_NAME]
    call dict_get
    V_UNPACK rax, rdx
    test edx, edx               ; the tag: a hit may be a false-looking payload
    jnz .tdd_yes
.tdd_next:
    MRO_NEXT rbx, [rbp - TDD_TYPE]
    jmp .tdd_walk
.tdd_yes:
    mov rdi, [rbp - TDD_NAME]
    call obj_decref
    mov eax, 1
    pop rbx
    leave
    ret
.tdd_no:
    mov rdi, [rbp - TDD_NAME]
    call obj_decref
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC type_defines_dunder

;; ============================================================================
;; object_new_staticbase(rdi = the type being constructed)
;;   -> rax = the type CPython calls `staticbase`
;;
;; CPython's tp_new_wrapper asks whether object's allocator is safe for a type
;; by climbing tp_base past every class that defines `__new__` in PYTHON, then
;; comparing what it lands on against object's own tp_new.  Its test for
;; "defines __new__ in Python" is `tp_new == slot_tp_new`; this tree has no
;; such slot -- a heaptype either inherits its base's tp_new or gets none --
;; so the equivalent question is asked of the dunder instead: whoever OWNS the
;; `__new__` this type would find is a heaptype exactly when that `__new__` is
;; a Python-level definition.
;;
;; The owner and not the type's own dict, because the property is inherited.
;; `class Mixed(P, L2)` defines no `__new__` of its own, but the one it finds
;; is L2's, written in Python -- CPython skips Mixed for that reason and
;; reports `list`, and asking Mixed's own dict would stop at Mixed and report
;; the wrong name.
;;
;; object always terminates the walk: its `__new__` is in its own dict and it
;; is not a heaptype, so a type with no Python-level `__new__` anywhere stops
;; at itself.
;; ============================================================================
ONS_OWNER equ 8
ONS_FRAME equ 24            ; + 1 push = 32, 16-aligned
DEF_FUNC object_new_staticbase, ONS_FRAME
    push rbx
    mov rbx, rdi
.ons_walk:
    test rbx, rbx
    jz .ons_done
    mov rdi, rbx
    lea rsi, [rel new_dunder_cstr]
    lea rdx, [rbp - ONS_OWNER]
    mov qword [rbp - ONS_OWNER], 0
    call dunder_lookup_owner
    V_UNPACK rax, rdx
    test edx, edx
    jz .ons_done                ; no __new__ at all: this is the staticbase
    mov rax, [rbp - ONS_OWNER]
    test rax, rax
    jz .ons_done
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_HEAPTYPE
    jz .ons_done                ; a builtin supplies it: stop here
    mov rbx, [rbx + PyTypeObject.tp_base]
    jmp .ons_walk
.ons_done:
    mov rax, rbx
    pop rbx
    leave
    ret
END_FUNC object_new_staticbase

;; ============================================================================
;; object_new_is_safe(rdi = the type being constructed, rsi = its staticbase)
;;   -> eax = 1 when object's allocator owns this layout, 0 when it does not
;;
;; CPython compares `staticbase->tp_new` against object's.  Here the same
;; question is "is the nearest STATIC base object itself": a heaptype whose
;; static ancestry ends at object has object's layout, and one that reaches
;; list, str or an exception does not.  tp_base is the layout-determining base
;; -- type_from_parts picks it the way CPython's best_base does -- so a
;; multiple-inheritance class follows the one that decided its storage.
;; ============================================================================
DEF_FUNC_BARE object_new_is_safe
    mov rax, rsi
.onis_walk:
    test rax, rax
    jz .onis_yes                ; no static base at all: not ours to refuse
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_HEAPTYPE
    jz .onis_static
    mov rax, [rax + PyTypeObject.tp_base]
    jmp .onis_walk
.onis_static:
    lea rcx, [rel object_type]
    cmp rax, rcx
    jne .onis_no
.onis_yes:
    mov eax, 1
    ret
.onis_no:
    xor eax, eax
    ret
END_FUNC object_new_is_safe

;; ============================================================================
;; object_new_fn(args, nargs) -> instance
;; Implements object.__new__(cls) — creates a bare instance of cls.
;; args[0] = cls (the type to instantiate)
;; ============================================================================
ONF_TYPE  equ 8
ONF_BASE  equ 16
ONF_NARGS equ 24
ONF_FRAME equ 32            ; + 0 pushes = 32, 16-aligned
DEF_FUNC object_new_fn, ONF_FRAME
    ; args[0] = cls
    ; args[0] is the type to build.  Nothing checked that there WAS one:
    ; `object.__new__()` read past the argument array and took the garbage it
    ; found as a PyTypeObject*, which segfaulted a few dereferences later.
    test rsi, rsi
    jz .onf_no_type
    mov [rbp - ONF_NARGS], rsi  ; the walk below clobbers rsi
    mov rdi, [rdi]              ; cls payload (PyTypeObject*)
    V_TEST_PTR rdi, rcx         ; ja when NULL or an immediate
    ja .onf_not_a_type
    mov rcx, [rdi + PyObject.ob_type]
    test qword [rcx + PyTypeObject.tp_flags], TYPE_FLAG_METATYPE
    jz .onf_not_a_type
    mov [rbp - ONF_TYPE], rdi

    ; Is object's allocator the right one for this type?  CPython asks first,
    ; before the argument count, and it has to be first here for a stronger
    ; reason: str, float and bytes keep their payload inline, so an instance
    ; built at object's size is freed by the type's own dealloc as though the
    ; storage were there.  That aborted the process rather than answering
    ; wrongly.
    call object_new_staticbase
    mov rsi, rax
    mov rdi, [rbp - ONF_TYPE]
    call object_new_is_safe
    test eax, eax
    jz .onf_unsafe

    ; Excess arguments are CPython's object_new error, not something to
    ; drop: a class that overrides neither half has nowhere to put them.
    mov rdi, [rbp - ONF_TYPE]
    mov rsi, [rbp - ONF_NARGS]
    cmp rsi, 1
    jbe .onf_build
    lea rsi, [rel new_dunder_cstr]
    mov edx, PyTypeObject.tp_new
    call type_defines_dunder
    test eax, eax
    jnz .onf_own_new
    mov rdi, [rbp - ONF_TYPE]
    lea rsi, [rel init_dunder_cstr]
    mov edx, PyTypeObject.tp_init
    call type_defines_dunder
    test eax, eax
    jz .onf_no_args
.onf_build:
    mov rdi, [rbp - ONF_TYPE]
    call instance_new
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx             ; builtins return one Value
    ret

.onf_no_type:
    RAISE exc_TypeError_type, "object.__new__(): not enough arguments"

.onf_not_a_type:
    ; CPython names what it got: "X is not a type object (int)".
    mov rsi, rdi
    CSTRING rdi, `object.__new__(X): X is not a type object (\x01)`
    jmp raise_type_error_with_name

.onf_unsafe:
    ; "object.__new__(C) is not safe, use B.__new__()" -- C is the type asked
    ; for and B the staticbase, and they differ whenever a Python-level
    ; __new__ sat between them.
    mov rdi, [rbp - ONF_TYPE]
    call object_new_staticbase
    mov [rbp - ONF_BASE], rax
    lea rdi, [rel onf_msgbuf]
    lea rsi, [rel onf_not_safe_open]
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - ONF_TYPE]
    mov rsi, [rsi + PyTypeObject.tp_name]
    call rbt_append_cstr
    mov rdi, rax
    lea rsi, [rel onf_not_safe_mid]
    call rbt_append_cstr
    mov rdi, rax
    mov rsi, [rbp - ONF_BASE]
    mov rsi, [rsi + PyTypeObject.tp_name]
    call rbt_append_cstr
    mov rdi, rax
    lea rsi, [rel onf_not_safe_tail]
    call rbt_append_cstr
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rel onf_msgbuf]
    call raise_exception
    ud2

.onf_own_new:
    RAISE exc_TypeError_type, \
          "object.__new__() takes exactly one argument (the type to instantiate)"
.onf_no_args:
    mov rsi, [rbp - ONF_TYPE]
    CSTRING rdi, `\x01() takes no arguments`
    jmp raise_type_error_with_typename
END_FUNC object_new_fn

section .rodata
onf_not_safe_open: db "object.__new__(", 0
onf_not_safe_mid:  db ") is not safe, use ", 0
onf_not_safe_tail: db ".__new__()", 0

section .bss
; Two type names and the fixed text.  Written only on the way to a raise, so
; it is never live across anything that could compose another message.
onf_msgbuf: resb 256

section .text
