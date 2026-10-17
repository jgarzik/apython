; opcodes/load_ic.asm - the inline-cache opcodes for loads
;
; The four specialized load handlers, each of which rewrites itself into the
; bytecode once the generic handler has seen what the site actually does, and
; each of which guards the shape it was specialized for:
;
;   200  LOAD_GLOBAL_MODULE     name found in the module globals
;   201  LOAD_GLOBAL_BUILTIN    name found in builtins
;   203  LOAD_ATTR_METHOD       a method reached through the type dict
;   204  LOAD_ATTR_INSTANCE     a plain attribute reached through the instance
;   240  STORE_ATTR_INSTANCE    a plain attribute written through the instance
;   242  LOAD_ATTR_PROPERTY     a @property, whose getter runs without a call
;
; Split out of load.asm, which keeps the generic handlers, the attribute
; protocol and the error messages, because that file had reached lint's 100k
; cap for a hand-written file with 107 bytes to spare -- so no fix to any of
; these could be written at all.  The seam is the one arith.asm and
; arith_spec.asm already use, and it works for the same reason: nothing here
; calls into load.asm's file-local helpers.  Each deopt writes the generic
; opcode byte back and jumps to the generic handler, entering it with ecx
; still holding the full oparg.
;
; That last point is not a detail.  LOAD_ATTR and LOAD_GLOBAL take a name
; index wide enough to carry an EXTENDED_ARG prefix, and op_extended_arg
; composes the full argument into ecx and jumps without leaving it anywhere in
; the byte stream.  Rewinding rbx by two to re-dispatch would land past the
; prefix and read the low byte as the whole argument; these deopt by jumping
; instead, and nothing between a handler's entry and its deopt label may touch
; rcx.

%include "macros.inc"
%include "object.inc"
%include "opcodes.inc"

extern opcode_dispatch_table
extern obj_dealloc
extern obj_decref
extern op_load_attr
extern op_load_global
extern op_store_attr

extern func_type
extern frame_new
extern frame_alloc_inline
extern frame_free
extern eval_frame
extern eval_exception_unwind
extern builtins_dict_global

section .text

;; ============================================================================
;; op_load_global_module (200) -> nothing; pushes the global and dispatches
;;
;; The specialized LOAD_GLOBAL for a name that was found in the module's own
;; globals.  Guards the globals dict's version and then reads the entry by its
;; cached dense index, which costs neither the hash nor the probe.
;;
;; The version guard runs BEFORE anything touches the value stack, so a deopt
;; has nothing to undo.
;;
;; CACHE layout at rbx: [+0]=counter [+2]=index [+4]=mod_ver [+6]=bi_ver
;; ============================================================================
DEF_FUNC_BARE op_load_global_module
    ; Version guard FIRST (before any stack modification)
    mov rdi, [r12 + PyFrame.globals]
    mov rax, [rdi + PyDictObject.dk_version]
    cmp ax, word [rbx + 4]     ; compare low 16 bits with CACHE[2]
    jne .lgm_deopt

    ; Fast path: load from globals entries by cached index
    mov rdi, [rdi + PyDictObject.entries]
    movzx eax, word [rbx + 2]  ; CACHE[1] = index
    imul rax, rax, DICT_ENTRY_SIZE
    add rdi, rax               ; rdi = entry ptr
    ; A deleted entry has a NULL value.  This tested edx BEFORE anything had
    ; loaded it -- a register the dispatcher leaves undefined -- so the guard
    ; answered at random: usually not taken, and taken for no reason when it
    ; happened to be zero.
    mov rax, [rdi + DictEntry.value]
    test rax, rax
    jz .lgm_deopt
    ; The NULL test above was already made on the RAW Value -- 0 is the only
    ; NULL encoding -- so nothing here ever needed the tag.

    ; Guards passed — now push NULL if needed
    test ecx, 1
    jz .lgm_no_null
    VPUSH_NULL
.lgm_no_null:
    INCREF_V rax, rdx
    VPUSH rax
    add rbx, 8
    DISPATCH

.lgm_deopt:
    ; Deopt into the generic handler with the argument ecx already
    ; holds.  Rewinding rbx by two and re-dispatching would drop a
    ; preceding EXTENDED_ARG, and both of these carry one as soon as
    ; a module has enough names: the arg is (name index << 1 | flag).
    mov byte [rbx - 2], 116
    jmp op_load_global
END_FUNC op_load_global_module

;; ============================================================================
;; op_load_global_builtin (201) -> nothing; pushes the builtin and dispatches
;;
;; The specialized LOAD_GLOBAL for a name that was not in the module globals
;; and was found in builtins.  Both dictionaries are guarded: the globals one
;; because the name may since have been defined there, which would shadow the
;; builtin, and the builtins one because the entry itself may have moved.
;; ============================================================================
DEF_FUNC_BARE op_load_global_builtin
    ; Guards FIRST (before any stack modification)
    ; Guard 1: globals version must not have changed (name might now be in globals)
    mov rdi, [r12 + PyFrame.globals]
    mov rax, [rdi + PyDictObject.dk_version]
    cmp ax, word [rbx + 4]     ; CACHE[2] = module_keys_version
    jne .lgb_deopt

    ; Guard 2: builtins version must match
    mov rdi, [r12 + PyFrame.builtins]
    mov rax, [rdi + PyDictObject.dk_version]
    cmp ax, word [rbx + 6]     ; CACHE[3] = builtin_keys_version
    jne .lgb_deopt

    ; Fast path: load from builtins entries by cached index
    mov rdi, [rdi + PyDictObject.entries]
    movzx eax, word [rbx + 2]  ; CACHE[1] = index
    imul rax, rax, DICT_ENTRY_SIZE
    add rdi, rax               ; rdi = entry ptr
    ; A deleted entry has a NULL value.  This tested edx BEFORE anything had
    ; loaded it -- a register the dispatcher leaves undefined -- so the guard
    ; answered at random: usually not taken, and taken for no reason when it
    ; happened to be zero.
    mov rax, [rdi + DictEntry.value]
    test rax, rax
    jz .lgb_deopt
    ; The NULL test above was already made on the RAW Value -- 0 is the only
    ; NULL encoding -- so nothing here ever needed the tag.

    ; Guards passed — now push NULL if needed
    test ecx, 1
    jz .lgb_no_null
    VPUSH_NULL
.lgb_no_null:
    INCREF_V rax, rdx
    VPUSH rax
    add rbx, 8
    DISPATCH

.lgb_deopt:
    ; Deopt into the generic handler with the argument ecx already
    ; holds.  Rewinding rbx by two and re-dispatching would drop a
    ; preceding EXTENDED_ARG, and both of these carry one as soon as
    ; a module has enough names: the arg is (name index << 1 | flag).
    mov byte [rbx - 2], 116
    jmp op_load_global
END_FUNC op_load_global_builtin

;; ============================================================================
;; op_load_attr_method (203) - Specialized LOAD_ATTR for method-style loads
;;
;; Fast path for flag=1 method loads from type dict (no tp_getattr path).
;; Guards: the type's VERSION matches, tp_dict dk_version matches, and the
;; instance dict cannot shadow the name.
;; CACHE layout at rbx: [+0]=type version(32b), [+4]=dk_version(16b),
;;                      [+6]=descr(64b)
;;
;; The version, and not the type POINTER this used to hold: versions come from
;; one global counter and are never reused, where an address is.  A class
;; freed and another allocated in its place passed the pointer compare, with
;; only sixteen bits of dk_version behind it and a cached descriptor belonging
;; to the dead class's dict -- so a warm site answered from the wrong class.
;; It takes a program that creates and drops classes at one call site to see,
;; which CPython's test_copy does, and whether the addresses coincide depends
;; on the heap: valgrind was clean over it and a different build laid it out
;; so it did not happen.
;;
;; Stack effect: ..., obj -> ..., obj(self), method
;; (obj stays as self, cached method pushed on top)
;; ============================================================================
DEF_FUNC_BARE op_load_attr_method
    ; ecx = arg (name_index << 1 | flag=1)
    ; VPEEK obj (don't pop -- stays as self if guards pass, or for deopt)
    VPEEK rdi

    ; The inline cache only applies to real objects
    V_TEST_PTR rdi, rax
    ja .lam_deopt

    ; Guard 1: the type's VERSION == the cached one
    mov rax, [rdi + PyObject.ob_type]
    mov rdx, [rax + PyTypeObject.tp_flags]
    shr rdx, TYPE_VERSION_SHIFT
    cmp edx, [rbx]                 ; CACHE[+0]
    jne .lam_deopt

    ; Guard 2: type->tp_dict->dk_version == cached dk_version
    mov rax, [rax + PyTypeObject.tp_dict]
    mov rax, [rax + PyDictObject.dk_version]
    cmp ax, word [rbx + 4]         ; CACHE[+4]
    jne .lam_deopt

    ; Guard 3: the INSTANCE dict cannot shadow the name.
    ;
    ; Neither guard above says anything about it -- one pins the class, the
    ; other the class's dict -- so a warm site went on calling the class's
    ; method after `c.m = something` put one on the instance.  That was a
    ; wrong ANSWER, not a slow one, and it needed the same call site to run
    ; before and after the shadow to see: a fresh site is cold and takes the
    ; generic path, which is why the obvious test missed it.
    ;
    ; The proof used here is the strong one: no dict, or an empty one.  Since
    ; instance dicts became lazy that covers every instance that has had
    ; nothing stored on it, which is what a method-heavy site mostly walks.
    ; An instance with attributes deopts and takes the generic path, which is
    ; where it was before this cache existed.
    ;
    ; A dict that exists and holds something is PROBED rather than refused:
    ; the question is whether THIS name is in it, and dict_lookup answers
    ; "no" the moment it reaches an empty slot.  Reaching one here is the
    ; same proof, so the guard concludes absence only from that -- an
    ; occupied slot, a tombstone or a long chain all deopt and let the
    ; generic handler decide.
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_dictoffset]
    test rax, rax
    jz .lam_no_shadow             ; no instance dict at all
    cmp rax, TP_DICT_AT_TAIL
    je .lam_deopt                 ; str and bytes subclasses keep it elsewhere
    mov rax, [rdi + rax]
    test rax, rax
    jz .lam_no_shadow             ; lazy, and never created
    cmp qword [rax + PyDictObject.ob_size], 0
    je .lam_no_shadow             ; empty: nothing to shadow with

    ; The name, whose hash is cached: LOAD_ATTR's names are interned.
    ;
    ; `mov esi, ecx`, not `mov rsi, rcx`: the oparg is a DWORD in ecx and the
    ; high half of rcx is whatever was there.  Taking all sixty-four bits made
    ; the name index enormous, which read a "name" from past the end of
    ; co_names, hashed it, and probed an unrelated slot -- and that slot was
    ; empty, so the guard reported absence for a name that was present.  The
    ; 32-bit move zero-extends, which is the whole fix.
    push rbx
    push r12
    LOAD_CO_NAMES rdx
    mov esi, ecx
    shr esi, 1                    ; the arg is (name index << 1 | flag)
    mov rdx, [rdx + rsi*8]        ; the name str
    mov r8, [rdx + PyStrObject.ob_hash]
    cmp r8, -1
    je .lam_shadow_deopt          ; unhashed: not worth computing here
    mov r11, [rax + PyDictObject.dk_indices]
    test r11, r11
    jz .lam_shadow_deopt          ; the tables are allocated lazily
    mov r9, [rax + PyDictObject.capacity]
    test r9, r9
    jz .lam_shadow_deopt
    dec r9                        ; the mask
    mov r10, r8
    and r10, r9                   ; the first slot dict_lookup would try
    mov r12d, 4                   ; at most four steps, then give up
.lam_probe:
    mov rsi, [r11 + r10*8]
    cmp rsi, DICT_IX_EMPTY
    je .lam_probe_absent          ; where dict_lookup stops and reports a miss
    cmp rsi, DICT_IX_DUMMY
    je .lam_probe_next            ; a tombstone: dict_lookup walks past it too

    ; An occupied slot has to be RULED OUT before walking past it.  Comparing
    ; the stored hash is what dict_lookup does first, and it is enough here:
    ; equal means it might be this name, so deopt and let the generic handler
    ; answer.  Skipping this test was the whole bug -- the probe walked past
    ; the slot the name was actually in and reported absence from the empty
    ; one after it.
    imul rsi, rsi, DICT_ENTRY_SIZE
    add rsi, [rax + PyDictObject.entries]
    cmp r8, [rsi + DictEntry.hash]
    je .lam_shadow_deopt

.lam_probe_next:
    dec r12d
    jz .lam_shadow_deopt
    inc r10
    and r10, r9
    jmp .lam_probe
.lam_probe_absent:
    pop r12
    pop rbx
.lam_no_shadow:

    ; Guards passed! CPython order: method (deeper), obj/self (TOS)
    ; obj is currently at [r13-8]; overwrite it with method, push obj on top
    mov rax, [rbx + 6]            ; cached descriptor (method ptr)
    INCREF rax
    mov rcx, [r13 - 8]            ; save obj (payload of TOS)
    mov [r13 - 8], rax            ; overwrite obj position with method
    VPUSH_PTR rcx                  ; push obj on top as self

    ; Skip 9 CACHE entries = 18 bytes
    add rbx, 18
    DISPATCH

.lam_shadow_deopt:
    pop r12
    pop rbx
    ; Fall through to the ordinary deopt.
.lam_deopt:
    ; Deopt into the generic handler with the argument ecx already
    ; holds.  Rewinding rbx by two and re-dispatching would drop a
    ; preceding EXTENDED_ARG, and both of these carry one as soon as
    ; a module has enough names: the arg is (name index << 1 | flag).
    mov byte [rbx - 2], 106
    jmp op_load_attr
END_FUNC op_load_attr_method

;; ============================================================================
;; op_load_attr_instance (204) -> nothing; replaces TOS with the attribute
;;
;; The data-load counterpart of LOAD_ATTR_METHOD.  A plain `self.x` had no
;; inline cache at all: LOAD_ATTR's only one was for methods, so an ordinary
;; attribute read went through op_load_attr's whole prologue, tp_getattr,
;; instance_getattr, instance_getattr_default, LOAD_INST_DICT and dict_get --
;; hashing the name and probing the table every time.  `c.m()` measured 0.40x
;; of CPython against 1.00x for a plain `f()`, and a profile put the
;; difference here rather than anywhere in the call machinery.
;;
;; CACHE, 18 bytes, the same budget the method cache spends:
;;     [+0]   the type's version, 4 bytes
;;     [+4]   the dense index into the instance dict's entry array, 2 bytes
;;     [+6]   spare
;;
;; The NAME is not cached.  It is taken from co_names at hit time, which costs
;; one load and leaves room for the version.
;;
;; CPython caches (type version, keys version, index) and can trust the index
;; because its instances share their keys object.  Ours do not: two instances
;; of one class can have completely different dict layouts, from an __init__
;; with a branch in it.  So the index is not trusted -- the KEY at that index
;; is compared against the name, which makes the read self-validating and
;; needs no INSTANCE dict version at all.  A hit is then exactly what dict_get
;; would have returned, without the hash or the probe.
;;
;; That comparison is by POINTER, which is why interning matters to this
;; opcode: dict_set keeps the FIRST writer's key object, so `self.x` read from
;; a method other than the one that wrote it used to fail the guard on every
;; execution when the two names were different objects.  See
;; src/pyo/strintern.asm.
;;
;; One version compare stands in for the three guards this used to make.  It
;; pins the type -- a freed class cannot be matched by a new one at the same
;; address, because versions come from a single counter -- and it pins
;; everything the install site checked about the MRO, because all of that moves
;; only through type_refresh_attr_flags, which stamps a new version and stamps
;; it down every subclass.
;; ============================================================================
DEF_FUNC_BARE op_load_attr_instance
    ; ecx is the oparg and MUST survive to .lai_deopt, which hands it to
    ; op_load_attr -- so nothing below touches rcx.  Getting that wrong is not
    ; a wrong answer, it is op_load_attr reading co_names out of bounds with a
    ; name index of (garbage >> 1), and the wild pointer surfaces later inside
    ; dict_get.
    VPEEK rdi                      ; the object; not popped until it is a hit
    V_TEST_PTR rdi, rax
    ja .lai_deopt

    ; Guard 1: the class, in the state the install site vetted it in.
    ;
    ; One compare where there used to be three.  The version pins the type --
    ; a freed class cannot be matched by a new one at the same address,
    ; because versions come from a single counter -- and it pins everything
    ; the install site checked about the MRO: that no __getattribute__ of the
    ; class's own runs, and that THIS NAME resolves to nothing that could
    ; outrank the instance dict.  All of those move only through
    ; type_refresh_attr_flags, which stamps a new version and stamps it down
    ; every subclass.
    mov rax, [rdi + PyObject.ob_type]
    mov rdx, [rax + PyTypeObject.tp_flags]
    shr rdx, TYPE_VERSION_SHIFT
    cmp edx, dword [rbx]           ; CACHE[+0] = the type's version
    jne .lai_deopt

    ; Guard 2: there is an instance dict, and the cached slot is inside the
    ; part of its dense array that has ever been used.
    LOAD_INST_DICT rsi, rdi, .lai_deopt
    test rsi, rsi
    jz .lai_deopt
    movzx r8d, word [rbx + 4]      ; CACHE[+4] = dense index
    cmp r8, [rsi + PyDictObject.dk_nentries]
    jae .lai_deopt

    ; Guard 3: that slot still holds THIS name.  The index alone proves
    ; nothing -- two instances of one class can have completely different dict
    ; layouts, from an __init__ with a branch in it -- so the KEY is compared,
    ; which makes the read self-validating and needs no instance dict version.
    ; The name comes from co_names rather than the cache: it is the site's own
    ; name, so it is always right, and a cached borrowed pointer to it would
    ; be one more thing to keep alive.
    ;
    ; That comparison is by POINTER, which is why interning matters here:
    ; dict_set keeps the FIRST writer's key object, so `self.x` read from a
    ; method other than the one that wrote it used to fail the guard on every
    ; execution when the two names were different objects.  See
    ; src/pyo/strintern.asm.
    mov rdx, [rsi + PyDictObject.entries]
    imul r8, r8, DICT_ENTRY_SIZE
    add rdx, r8
    mov r9d, ecx                   ; the oparg, untouched
    shr r9d, 1                     ; arg >> 1 = the co_names index
    shl r9d, 3
    LOAD_CO_NAMES r10
    mov r9, [r10 + r9]
    cmp r9, [rdx + DictEntry.key]
    jne .lai_deopt

    ; Guard 4: it is not a hole.  A deleted entry keeps its position with a
    ; NULL key, which guard 3 already covers; this covers a NULL value.
    mov rax, [rdx + DictEntry.value]
    test rax, rax
    jz .lai_deopt

    ; Hit.  attr_error_pending says a __getattr__ raised an AttributeError
    ; that raise_no_attribute should hand over rather than replace, and every
    ; ordinary lookup clears it -- object.asm calls that "it cannot survive a
    ; lookup".  This is a lookup.
    CLEAR_ATTR_ERROR_PENDING

    ; INCREF the attribute BEFORE releasing the object: the object may hold
    ; the only reference to the dict the attribute lives in.
    INCREF_V rax, rdx
    mov [r13 - 8], rax             ; the attribute replaces the object
    DECREF_V rdi, rdx              ; rdi is still the object

    add rbx, 18                    ; skip 9 CACHE entries
    DISPATCH

.lai_deopt:
    ; Deopt into the generic handler with the argument ecx still holds.
    ; Rewinding rbx cannot be done here: LOAD_ATTR's arg is
    ; (name index << 1 | flag) and carries an EXTENDED_ARG as soon as a module
    ; has enough names.
    mov byte [rbx - 2], 106
    jmp op_load_attr
END_FUNC op_load_attr_instance


;; ============================================================================
;; op_load_attr_property (242) -> nothing; replaces TOS with the getter's result
;;
;; `self.scale` where scale is a @property.  The generic handler reaches the
;; getter through op_load_attr's whole prologue, instance_getattr,
;; instance_getattr_where, the descriptor protocol, property_descr_get and
;; obj_call_n -- and then obj_call_n builds the frame the ordinary call path
;; builds.  Decomposing m_oo put the entire remaining gap here: a method whose
;; body reads one property cost 45.8ms against CPython's 34.8, where the same
;; body reading a plain attribute instead cost 19.4 against 28.1.  Per access
;; that is about 33ns against CPython's 8.
;;
;; So this does what CPython's LOAD_ATTR_PROPERTY does: guard, then push the
;; getter's frame directly, the way op_call_py_exact pushes a call's.  What is
;; NOT taken is the same thing op_call_py_exact leaves alone -- eval_frame and
;; the frame allocation.
;;
;; CACHE, 18 bytes:
;;     [+0]   the type's version, 4 bytes
;;     [+4]   the getter, 8 bytes -- a borrowed pointer, as 203's descriptor is
;;     [+12]  spare
;;
;; The version pins the property: a property object cannot be mutated (its
;; tp_setattr takes __doc__ and nothing else) and rebinding the class attribute
;; goes through type_setattr, which stamps a new version and stamps it down
;; every subclass.  So the getter needs no guard of its own -- except that a
;; FUNCTION can be given a different __code__, which is why the code object is
;; read at every hit rather than vetted once.
;;
;; Only flag=0 sites install: a method-style load of a property would have to
;; push [NULL, value], and `obj.prop()` is not a shape worth a second layout.
;;
;; A getter that is not a plain one-parameter Python function -- a lambda with
;; a default, a builtin, a generator -- deopts and takes the road it took
;; before this existed.
;; ============================================================================
LAP_OBJ   equ 8
LAP_RET   equ 16
LAP_ARG   equ 24                ; the oparg, which frame_new's rcx destroys
LAP_FN    equ 32                ; the getter, held across its own frame
LAP_FRAME equ 40                ; a handler is entered with rsp 16-aligned, so
                                ; push rbp + 40 brings it back to aligned

DEF_FUNC op_load_attr_property, LAP_FRAME
    ; ecx is the oparg and must survive to .lap_deopt, which hands it to
    ; op_load_attr, so nothing before the last guard touches rcx.
    VPEEK rdi                       ; the object; not popped until it is a hit
    V_TEST_PTR rdi, rax
    ja .lap_deopt

    ; Guard 1: the class, in the state the install site vetted it in.  It pins
    ; the property the cached getter came out of, and everything the install
    ; checked about the MRO -- all of that moves only through
    ; type_refresh_attr_flags, which stamps a new version down every subclass.
    mov rax, [rdi + PyObject.ob_type]
    mov rdx, [rax + PyTypeObject.tp_flags]
    shr rdx, TYPE_VERSION_SHIFT
    cmp edx, dword [rbx]            ; CACHE[+0] = the type's version
    jne .lap_deopt

    ; Guard 2: the getter is still a shape this can run inline -- a plain
    ; Python function of exactly one parameter that does not suspend.  The
    ; property is pinned above, but `fget.__code__ = ...` is a write to the
    ; FUNCTION, which no version covers, so the code object is read here.
    mov rsi, [rbx + 4]              ; CACHE[+4] = the getter
    lea rax, [rel func_type]
    cmp [rsi + PyObject.ob_type], rax
    jne .lap_deopt
    mov rax, [rsi + PyFuncObject.func_code]
    cmp dword [rax + PyCodeObject.co_argcount], 1
    jne .lap_deopt
    cmp dword [rax + PyCodeObject.co_kwonlyargcount], 0
    jne .lap_deopt
    test dword [rax + PyCodeObject.co_flags], \
         CO_VARARGS | CO_VARKEYWORDS | CO_GENERATOR | CO_COROUTINE | \
         CO_ASYNC_GENERATOR
    jnz .lap_deopt

    ; Past the last guard, so rcx is free -- but the name is still wanted on
    ; the error path below, and by then frame_new will have had rcx.
    mov [rbp - LAP_OBJ], rdi
    mov [rbp - LAP_ARG], rcx

    ; The cached getter is BORROWED -- pinned by the type version, which is
    ; enough right up until the getter deletes itself: `del type(self).v`
    ; inside one drops the property, which drops the function whose code this
    ; frame is about to run.  op_call_py_exact has the callable's stack
    ; reference for the same window; this has none, so it takes one.
    ; CPython's _PyFrame_PushUnspecialized does the same.
    mov [rbp - LAP_FN], rsi
    INCREF rsi

    ; The frame, built here rather than by frame_new -- the code object, its
    ; two size fields and the getter's globals are all in hand, and the one
    ; argument is the object.  Same shape as op_call_py_exact's, and off the
    ; same datastack: this frame nests exactly as an inline call's does,
    ; because the guards above refuse every shape that could return with it
    ; still live, and it is released unconditionally below.
    ;
    ; It is NOT entered inline -- entry_kind stays FRAME_ENTRY_CALL and
    ; eval_frame is still called -- because this handler's resume has a
    ; __getattr__ fallback in it that the call's does not.
    mov r8d, [rax + PyCodeObject.co_nlocalsplus]
    mov r9d, [rax + PyCodeObject.co_stacksize]
    add r9, r8
    shl r9, 3
    add r9, FRAME_HEADER_SIZE

    mov r15, [gs:ThreadState.frame_datastack_top]
    lea rdx, [r15 + r9]
    cmp rdx, [gs:ThreadState.frame_datastack_end]
    ja .lap_frame_slow
    mov [gs:ThreadState.frame_datastack_top], rdx

.lap_frame_ready:
    ; frame_new's header, minus prev_frame -- eval_frame overwrites that from
    ; eval_saved_r12 a few instructions later, and nothing runs in between.
    ; entry_slots is not written: nothing reads it while entry_kind is
    ; FRAME_ENTRY_CALL.
    mov [r15 + PyFrame.code], rax
    mov rdx, [rsi + PyFuncObject.func_globals]
    mov [r15 + PyFrame.globals], rdx
    mov rdx, [rel builtins_dict_global]
    mov [r15 + PyFrame.builtins], rdx
    mov [r15 + PyFrame.func_obj], rsi
    mov qword [r15 + PyFrame.locals], 0
    mov qword [r15 + PyFrame.instr_ptr], 0
    mov qword [r15 + PyFrame.stack_ptr], 0
    mov qword [r15 + PyFrame.disp_ip], 0
    mov qword [r15 + PyFrame.exc_state], 0
    mov qword [r15 + PyFrame.frame_obj], 0
    mov qword [r15 + PyFrame.gen_owner], 0
    mov dword [r15 + PyFrame.exc_depth], 0
    mov dword [r15 + PyFrame.entry_kind], FRAME_ENTRY_CALL
    mov [r15 + PyFrame.nlocalsplus], r8d
    lea rdx, [r15 + PyFrame.localsplus]
    lea rcx, [rdx + r8*8]
    mov [r15 + PyFrame.stack_base], rcx

    ; The getter's one parameter is the object, and that store is also this
    ; slot's initialisation -- only the slots beyond it need zeroing.
    mov rdx, [rbp - LAP_OBJ]
    INCREF_V rdx, rcx
    mov [r15 + PyFrame.localsplus], rdx
    mov edx, 1
    cmp edx, r8d
    jae .lap_run
.lap_zero:
    mov qword [r15 + PyFrame.localsplus + rdx*8], 0
    inc edx
    cmp edx, r8d
    jb .lap_zero

.lap_run:
    mov rdi, r15
    call eval_frame
    mov [rbp - LAP_RET], rax
    mov rdi, r15
    call frame_free
    mov rdi, [rbp - LAP_FN]
    call obj_decref

    mov rax, [rbp - LAP_RET]
    test rax, rax
    jnz .lap_have

    ; The getter raised.  An AttributeError out of one is the attribute saying
    ; it is absent, not a failure, and __getattr__ is the hook for exactly
    ; that -- the generic handler asks the same question at .la_prop_call.
    mov rdi, [rbp - LAP_OBJ]
    mov esi, [rbp - LAP_ARG]
    shr esi, 1                      ; the arg is (name index << 1 | flag)
    shl esi, 3
    LOAD_CO_NAMES rcx
    mov rsi, [rcx + rsi]
    extern attr_getattr_hook
    call attr_getattr_hook          ; -> (rax, edx); edx = 0 leaves it pending
    V_PACK rax, rdx
    test rax, rax
    jz .lap_propagate
.lap_have:

    ; attr_error_pending says a __getattr__ raised an AttributeError that
    ; raise_no_attribute should hand over rather than replace, and every
    ; ordinary lookup clears it.  This is a lookup.
    CLEAR_ATTR_ERROR_PENDING

    mov rdi, [rbp - LAP_OBJ]
    mov [r13 - 8], rax              ; the result replaces the object
    DECREF_V rdi, rdx               ; whose stack reference is now spent
    add rbx, 18                     ; skip 9 CACHE entries
    leave
    DISPATCH

.lap_propagate:
    ; The getter raised.  The object goes, as op_call_py_exact releases its
    ; arguments before propagating, and rbx is not advanced: the unwinder
    ; reads the current IP from PyFrame.disp_ip, which DISPATCH set.
    mov rdi, [rbp - LAP_OBJ]
    DECREF_V rdi, rdx
    sub r13, 8
    leave
    PUBLISH_SP
    jmp eval_exception_unwind

.lap_frame_slow:
    ; The region does not exist yet, or has no room: frame_alloc_inline makes
    ; it or falls back to the pool.  Two pushes, so rsp keeps its alignment.
    push rax
    push rax
    mov rdi, r9
    call frame_alloc_inline
    mov r15, rax
    pop rax
    pop rax
    mov rsi, [rbp - LAP_FN]         ; the getter, and r8 with it: both are
    mov r8d, [rax + PyCodeObject.co_nlocalsplus]    ; caller-saved
    jmp .lap_frame_ready

.lap_deopt:
    ; LOAD_ATTR's arg is (name index << 1 | flag) and carries an EXTENDED_ARG
    ; as soon as a module has enough names, so this jumps with ecx rather than
    ; rewinding rbx.  Nothing has been popped.
    mov byte [rbx - 2], 106
    leave
    jmp op_load_attr
END_FUNC op_load_attr_property

;; ============================================================================
;; op_store_attr_instance (240) -> nothing; stores and pops both operands
;;
;; `self.x = v` where x already exists in the instance dict.  The generic
;; handler builds an 88-byte frame, saves the exception state, walks the MRO
;; for a data descriptor, calls tp_setattr, and instance_setattr then walks the
;; same MRO again before reaching dict_set, which hashes the name and probes.
;; This writes the entry in place.
;;
;; CACHE, 8 bytes -- STORE_ATTR's four entries, which held nothing until now:
;;     [+0]  the type's version, 4 bytes
;;     [+4]  the dense index into the instance dict's entry array, 2 bytes
;;     [+6]  spare
;;
;; Eight bytes is why the version exists.  LOAD_ATTR_INSTANCE has eighteen and
;; spends ten of them on a type POINTER plus the class dict's version; there is
;; no room for that here, and a four-byte version answers both questions at
;; once -- it names one type in one state of its dict.
;;
;; What the version stands in for: the install site below checks that
;; tp_setattr is instance_setattr and that no data descriptor is in the MRO,
;; and records the version that was true when it did.  Either of those can only
;; change through type_setattr, which runs type_install_slots and then
;; type_refresh_attr_flags, which stamps a new version -- and stamps it down
;; every subclass too.  So a matching version means both still hold.
;;
;; The INDEX is not trusted, exactly as it is not on the load side: two
;; instances of one class can have different dict layouts, so the key at that
;; slot is compared against co_names[arg] by pointer, which makes the write
;; self-validating.
;;
;; dk_version is deliberately NOT bumped.  dict_set bumps it on every write
;; including a rebind, which is why a store-side cache cannot guard on it; an
;; in-place update of a value changes neither the layout nor the size, and
;; nothing guards on an instance dict's version anyway.
;; ============================================================================
DEF_FUNC_BARE op_store_attr_instance
    ; ecx is the oparg and must survive to .sai_deopt, so nothing before it
    ; touches rcx.  Stack: ... value, obj -- obj on top.
    mov rdi, [r13 - 8]              ; the object
    V_TEST_PTR rdi, rax
    ja .sai_deopt

    ; Guard 1: the type, in the state the install site vetted it in.
    mov rax, [rdi + PyObject.ob_type]
    mov rdx, [rax + PyTypeObject.tp_flags]
    shr rdx, TYPE_VERSION_SHIFT
    cmp edx, dword [rbx]            ; CACHE[+0] = version
    jne .sai_deopt

    ; Guard 2: there is an instance dict, and the cached slot is inside the
    ; part of its dense array that has ever been used.
    LOAD_INST_DICT rsi, rdi, .sai_deopt
    test rsi, rsi
    jz .sai_deopt
    movzx r8d, word [rbx + 4]       ; CACHE[+4] = dense index
    cmp r8, [rsi + PyDictObject.dk_nentries]
    jae .sai_deopt

    ; Guard 3: that slot still holds THIS name, compared by pointer.
    mov rdx, [rsi + PyDictObject.entries]
    imul r8, r8, DICT_ENTRY_SIZE
    add rdx, r8                     ; rdx = the entry
    mov r9d, ecx                    ; the oparg, untouched
    shl r9d, 3
    LOAD_CO_NAMES r10
    mov r9, [r10 + r9]
    cmp r9, [rdx + DictEntry.key]
    jne .sai_deopt

    ; Guard 4: it is not a hole.  Filling one would have to move
    ; dk_nentries and ob_size, which is dict_set's job, not this one's.
    cmp qword [rdx + DictEntry.value], 0
    je .sai_deopt

    ; Guard 5: the collector can see this dict, or the value cannot make a
    ; cycle anyway.
    ;
    ; A dict enters a generation lazily, the first time dict_set is given a
    ; key or value worth tracing -- dict_maybe_track does it, and an in-place
    ; write here does not go near dict_set.  An instance whose __init__ only
    ; assigned numbers therefore has an UNTRACKED dict, and writing the first
    ; object reference into it inline left the collector unable to see the
    ; reference at all: two nodes pointing at each other through such a dict
    ; were never collected and their __del__ never ran.
    ;
    ; Storing an immediate cannot create a cycle, so it is safe either way and
    ; keeps the ordinary `p.x = i` loop on the fast path.  A pointer into an
    ; untracked dict goes the long way round, and the dict_set it lands in
    ; tracks the dict, so the site is back on the fast path next time.
    cmp qword [rsi - GC_HEAD_SIZE + PyGC_Head.gc_next], 0
    jne .sai_tracked
    mov rax, [r13 - 16]
    V_TEST_PTR rax, r9              ; r9, not rcx: this branch can deopt, and
                                    ; the deopt hands ecx to op_store_attr
    jbe .sai_deopt
.sai_tracked:

    ; Hit.  Past the last guard, so rcx is free.
    mov rsi, [r13 - 16]             ; the value, owned by the stack
    mov rax, [rdx + DictEntry.value]
    mov [rdx + DictEntry.value], rsi ; the dict takes the stack's reference
    sub r13, 16                     ; both operands are consumed

    ; The object is parked in a callee-saved register: releasing the old value
    ; can call obj_dealloc, and that clobbers every caller-saved one.
    mov r15, rdi
    DECREF_V rax, rcx               ; the value that was there
    DECREF_V r15, rcx               ; the object's stack reference

    add rbx, 8                      ; skip 4 CACHE entries
    DISPATCH

.sai_deopt:
    ; STORE_ATTR's arg is a name index and carries an EXTENDED_ARG as soon as a
    ; module has enough names, so the deopt jumps with ecx rather than
    ; rewinding rbx.  Nothing has been popped.
    ;
    ; Ask the install site not to try again for a while.  A STORE_ATTR in an
    ; __init__ can never hit this cache on the object it just built -- guard 2
    ; wants the cached index inside dk_nentries and a fresh instance's dict has
    ; none -- so without the backoff the site specialized on every store and
    ; deoptimized on the next, writing its own instruction byte twice per
    ; constructed object for the life of the program.
    mov word [rbx + 6], 63          ; STS_BACKOFF_N, in src/opcodes/load.asm
    mov byte [rbx - 2], OP_STORE_ATTR
    jmp op_store_attr
END_FUNC op_store_attr_instance


;; ============================================================================
;; op_store_attr_slot (243) -> nothing; writes TOS1 into TOS's __slots__ slot
;;
;; `self.x = v` where x is a __slots__ member.  STORE_ATTR_INSTANCE cannot
;; serve it and must not try -- a member descriptor is a data descriptor, and
;; that handler writes into the instance dict, which a slotted class does not
;; have.  So a class with __slots__ specialized NOTHING: every store ran the
;; generic handler, and callgrind put three type_lookup_cached calls and
;; instance_setattr's own walk behind each one.  Two stores in an __init__
;; were a fifth of a `C(1, 2)` construction loop.
;;
;; A slot is simpler than a dict entry, and the cache is simpler with it: the
;; offset is fixed by the CLASS, so there is no index to distrust and no key
;; to compare.  One version guard answers everything -- that tp_setattr is
;; instance_setattr, that this name resolves to a member descriptor of this
;; class, and that its md_offset is the cached one.  All three move only
;; through type_setattr, which runs type_refresh_attr_flags, which stamps a
;; new version down every subclass.
;;
;; CACHE, 8 bytes -- STORE_ATTR's four entries, laid out as 240's are:
;;     [+0]   the type's version, 4 bytes
;;     [+4]   md_offset, a SIGNED 16-bit byte offset.  Signed because a str
;;            subclass addresses its slots from the tail with a negative one;
;;            16-bit because [+6] is the backoff counter 240 defined, and the
;;            install site refuses an offset that does not fit.
;;     [+6]   the deopt backoff counter
;; ============================================================================
DEF_FUNC_BARE op_store_attr_slot
    ; ecx is the oparg and must survive to .sas_deopt, which hands it to
    ; op_store_attr -- so nothing below touches rcx until the last guard has
    ; passed.  Stack: ... value, obj -- obj on top.
    mov rdi, [r13 - 8]              ; the object
    V_TEST_PTR rdi, rax
    ja .sas_deopt

    mov rax, [rdi + PyObject.ob_type]
    mov rdx, [rax + PyTypeObject.tp_flags]
    shr rdx, TYPE_VERSION_SHIFT
    cmp edx, dword [rbx]            ; CACHE[+0] = version
    jne .sas_deopt

    ; Hit.  Past the last guard, so rcx is free.
    movsx rdx, word [rbx + 4]       ; CACHE[+4] = md_offset, signed
    SLOT_ADDR rsi, rdi, rdx         ; rsi = &slot

    mov r8, [r13 - 16]              ; the value, owned by the stack
    mov rax, [rsi]                  ; whatever the slot held, 0 when unset
    mov [rsi], r8                   ; the slot takes the stack's reference
    sub r13, 16                     ; both operands are consumed

    ; The object goes in a callee-saved register: releasing the old value can
    ; call obj_dealloc, and that clobbers every caller-saved one.
    mov r15, rdi
    XDECREF_V rax, rcx              ; NULL-safe: the slot may never have been set
    DECREF_V r15, rcx               ; the object's stack reference

    add rbx, 8                      ; skip 4 CACHE entries
    DISPATCH

.sas_deopt:
    ; As 240's: STORE_ATTR's arg carries an EXTENDED_ARG as soon as a module
    ; has enough names, so the deopt jumps with ecx rather than rewinding rbx.
    ; Nothing has been popped.
    mov word [rbx + 6], 63          ; STS_BACKOFF_N, in src/opcodes/store.asm
    mov byte [rbx - 2], OP_STORE_ATTR
    jmp op_store_attr
END_FUNC op_store_attr_slot
