; object.inc - Object layout definitions for apython

%ifndef OBJECT_INC
%define OBJECT_INC

; PyObject base structure
struc PyObject
    .ob_refcnt: resq 1    ; +0: reference count (int64)
    .ob_type:   resq 1    ; +8: pointer to type object
endstruc

OBJ_HEADER_SIZE equ PyObject_size  ; 16

; PyVarObject (variable-size objects)
struc PyVarObject
    .ob_refcnt: resq 1    ; +0
    .ob_type:   resq 1    ; +8
    .ob_size:   resq 1    ; +16: number of items
endstruc

; Integer object (GMP-backed)
; CPython's integer hash modulus (PyHASH_MODULUS = 2^61 - 1 on 64-bit).
; sign(v) * (|v| mod PYHASH_MODULUS); see int_hash_i64 in src/pyo/int.asm.
PYHASH_MODULUS equ 0x1FFFFFFFFFFFFFFF

; mpz_t is a struct: { int _mp_alloc, int _mp_size, mp_limb_t *_mp_d }
; On x86-64 GMP: sizeof(mpz_t) = 16 bytes (4+4+8)
; An integer is "compact" when its value fits in int64: .ival holds it and
; .mpz is UNINITIALIZED, so creating one costs no GMP init and no limb
; allocation.  Anything wider is GMP-backed (.compact == 0, .mpz valid).
; Reading .mpz on a possibly-compact object requires INT_NEED_MPZ first,
; which promotes in place.  .mpz stays at +16 so existing GMP code is
; unaffected.
struc PyIntObject
    .ob_refcnt: resq 1    ; +0
    .ob_type:   resq 1    ; +8
    .mpz:       resb 16   ; +16: inline mpz_t (alloc:4, size:4, *d:8)
    .ival:      resq 1    ; +32: int64 value      (valid iff .compact != 0)
    .compact:   resq 1    ; +40: 1 = compact, 0 = GMP-backed
endstruc

; Promote a possibly-compact PyIntObject to GMP form in place.  Two
; instructions when it is already GMP-backed; int_promote_mpz preserves every
; register, so this is safe to drop in front of any .mpz access.
%macro INT_NEED_MPZ 1           ; %1 = register holding PyIntObject*
    cmp qword [%1 + PyIntObject.compact], 0
    je %%done
%ifidni %1, rdi
    call int_promote_mpz
%else
    push rdi
    sub rsp, 8                  ; the lone push flips the parity, and
                                ; int_promote_mpz reaches GMP.  Only visible
                                ; under INT_STRESS=1, where the promotion
                                ; actually fires: tests/gmp_align_probe.sh
                                ; counted 26 misaligned calls to
                                ; __gmpz_fits_slong_p through here.
    mov rdi, %1
    call int_promote_mpz
    add rsp, 8
    pop rdi
%endif
%%done:
%endmacro

; Float object
struc PyFloatObject
    .ob_refcnt: resq 1    ; +0
    .ob_type:   resq 1    ; +8
    .value:     resq 1    ; +16: double value
endstruc

; Complex object.
;
; Unlike float -- which is a NaN-boxed immediate, leaving PyFloatObject above
; all but vestigial -- a complex is a real heap object.  A pointer is its own
; Value, so the box is untouched and --selftest-value has nothing to say about
; it.  It holds two raw doubles and no references, so it is invisible to the
; collector: no tp_traverse, no tp_clear, no TYPE_FLAG_HAVE_GC, and ap_malloc
; rather than gc_alloc (gc_alloc hands back raw + GC_HEAD_SIZE, which
; obj_dealloc's plain-free path would hand to ap_free unshifted).
struc PyComplexObject
    .ob_refcnt: resq 1    ; +0
    .ob_type:   resq 1    ; +8
    .cval_real: resq 1    ; +16: double
    .cval_imag: resq 1    ; +24: double
endstruc

; String object
; A str stores UTF-8 and carries both lengths: ob_size is what the bytes
; occupy, ob_length is how many code points that is.  Python counts in code
; points, C counts in bytes, and almost every string here is ASCII -- where
; the two are equal, which is the fast path every code-point-aware operation
; checks first.
struc PyStrObject
    .ob_refcnt: resq 1    ; +0
    .ob_type:   resq 1    ; +8
    .ob_size:   resq 1    ; +16: length in bytes
    .ob_hash:   resq 1    ; +24: cached hash (-1 = not computed)
    .ob_length: resq 1    ; +32: length in code points
    .data:                 ; +40: null-terminated UTF-8 bytes (variable)
endstruc

; Bytes object
struc PyBytesObject
    .ob_refcnt: resq 1    ; +0
    .ob_type:   resq 1    ; +8
    .ob_size:   resq 1    ; +16: length in bytes
    .data:                 ; +24: raw bytes (variable)
endstruc

; ByteArray object.  Unlike bytes, the data is OUT OF LINE: a bytearray is
; mutable and grows, and inline data at a fixed offset in the object body
; cannot -- which is why it used to have no append, no extend and no slice
; assignment at all.  ob_bytes is its own allocation, doubling as it fills, so
; appending n bytes costs O(n) copies in total.  The compiler's Buf is the
; same shape.
;
; The buffer is always NUL-terminated one byte past ob_size, so the data
; pointer can be handed to anything that wants a C string; ob_cap counts the
; usable bytes and excludes that terminator.
; array.array: a mutable sequence of C scalars, one typecode for the lot.
; ob_data holds RAW SCALARS and not Values -- an array of 'i' is four-byte
; machine integers -- which is why the type has no tp_traverse and no
; tp_clear: there is nothing in there for the collector to follow, and giving
; it one would have it read integers as pointers.
struc PyArrayObject
    .ob_refcnt:  resq 1   ; +0
    .ob_type:    resq 1   ; +8
    .ob_size:    resq 1   ; +16: item COUNT, not bytes
    .ob_cap:     resq 1   ; +24: items that fit in ob_data
    .ob_data:    resq 1   ; +32: the buffer, or 0 when empty
    .ob_code:    resq 1   ; +40: the typecode letter
    .ob_isize:   resq 1   ; +48: bytes per item
    .ob_kind:    resq 1   ; +56: AK_SIGNED / AK_UNSIGNED / AK_FLOAT / AK_UNICODE
    .ob_exports: resq 1   ; +64: live views over ob_data, which block a resize
endstruc

struc PyByteArrayObject
    .ob_refcnt: resq 1    ; +0
    .ob_type:   resq 1    ; +8
    .ob_size:   resq 1    ; +16: length in bytes
    .ob_cap:    resq 1    ; +24: usable bytes at ob_bytes, excluding the NUL
    .ob_bytes:  resq 1    ; +32: the buffer
    .ob_exports: resq 1   ; +40: live memoryviews over it, which block a resize
endstruc

; MemoryView object — reference to a slice of a bytes-like object
struc PyMemoryViewObject
    .ob_refcnt: resq 1    ; +0
    .ob_type:   resq 1    ; +8
    .mv_source: resq 1    ; +16: the source object, strong; 0 once released
    .mv_buf:    resq 1    ; +24: the start of the data; 0 once released
    .mv_len:    resq 1    ; +32: the view's length in BYTES, not items
    .mv_itemsize: resq 1  ; +40: bytes per item, 1 unless cast()
    .mv_format:   resq 1  ; +48: the one-character format, as a C string
    .mv_readonly: resq 1  ; +56: 1 for a view over bytes
    ; The step between items, in ITEMS, signed.  1 for every view that comes
    ; from a buffer or from a contiguous slice; anything else is what `mv[::2]`
    ; and `mv[::-1]` produce, and mv_buf then points at the FIRST item of the
    ; view rather than at the lowest address in it.  MV_ITEM_ADDR is the one
    ; place that knows, and mv_stride == 1 is what `c_contiguous` answers and
    ; what anything handing the raw pointer to a syscall has to insist on.
    .mv_stride:   resq 1  ; +64
endstruc

; A released memoryview: mv_buf is 0 and every operation raises.  The source
; reference is dropped at that moment rather than at dealloc, which is the
; point of release() -- it lets the buffer's owner resize again.
MV_RELEASED equ 0

; List object
struc PyListObject
    .ob_refcnt: resq 1    ; +0
    .ob_type:   resq 1    ; +8
    .ob_size:   resq 1    ; +16: item count
    .allocated: resq 1    ; +24: capacity
    .ob_item:   resq 1    ; +32: ptr to payload (u64[]) array
endstruc

; Weak reference (src/pyo/weakrefmod.asm).  The referent is borrowed and is
; zeroed when it dies; the side table in that file owns the reference objects.
struc PyWeakRefObject
    .ob_refcnt:   resq 1  ; +0
    .ob_type:     resq 1  ; +8
    .wr_object:   resq 1  ; +16: the referent, 0 once it is gone
    .wr_callback: resq 1  ; +24: owned callable, or 0
    .wr_hash:     resq 1  ; +32: cached hash, -1 until computed
endstruc

; Tuple object
struc PyTupleObject
    .ob_refcnt: resq 1    ; +0
    .ob_type:   resq 1    ; +8
    .ob_size:   resq 1    ; +16: item count
    .ob_hash:   resq 1    ; +24: cached hash (-1 = not computed)
    .ob_item:   resq 1     ; +32: ptr to payload (u64[]) array
endstruc

; Dict object
struc PyDictObject
    .ob_refcnt: resq 1    ; +0
    .ob_type:   resq 1    ; +8
    .ob_size:   resq 1    ; +16: item count
    .capacity:  resq 1    ; +24: hash table capacity
    .entries:   resq 1    ; +32: ptr to entry array
    .dk_version: resq 1   ; +40: version counter (bumped on mutation)
    .dk_tombstones: resq 1 ; +48: count of deleted (holed) entries
    ; Compact layout, appended so `set` -- which shares this header but has
    ; its own entry code -- is unaffected by their presence.
    .dk_indices: resq 1   ; +56: ptr to int64[capacity], -1 empty, -2 dummy,
                          ;      else an index into .entries
    .dk_nentries: resq 1  ; +64: high-water mark of .entries in use
    ; Non-zero while every key in the table is an exact str -- vacuously true
    ; of an empty one, and cleared for good the moment a key of any other type
    ; goes in.  It is what lets the str probe loop skip asking whether the
    ; STORED key is a str too, which is a load and two compares on every
    ; hash-matching probe.  CPython's dk_kind, one bit of it.
    .dk_kind: resq 1      ; +72
endstruc

; The dict is CPython's compact layout: a sparse index array over a *dense*
; entry array appended in insertion order.  Iteration walks the dense array,
; which is why dict order is insertion order.  The unused tail of .entries is
; kept zeroed, so a walker that scans 0..capacity and skips key == 0 reads
; the same items in the same order without knowing about .dk_nentries.
DICT_IX_EMPTY equ -1
DICT_IX_DUMMY equ -2

; Dict entry
; An entry's state lives in .key and .hash rather than in a tag byte:
;   occupied  -> .key != 0
;   empty     -> .key == 0 and .hash == 0
;   tombstone -> .key == 0 and .hash == -1
; A key Value is never 0, and CPython's hash never returns -1 (it maps -1 to
; -2), so the three states are distinct and each test is an imm32 compare.
struc DictEntry
    .hash:      resq 1     ; +0:  cached hash of key (-1 marks a tombstone)
    .key:       resq 1     ; +8:  key Value (0 when not occupied)
    .value:     resq 1     ; +16: value Value
endstruc

DICT_ENTRY_SIZE equ DictEntry_size  ; 24
DICT_INIT_CAP   equ 8               ; initial hash-table slots for dict and set

; How far the hash is shifted down for each step of the probe recurrence,
; i = (i*5 + perturb + 1) & mask.  CPython's PERTURB_SHIFT, and Tim Peters'
; note that 4 and 6 were not significantly worse.
PERTURB_SHIFT   equ 5

; A set uses the same recurrence, and that is NOT what CPython does: its set
; walks LINEAR_PROBES (9) consecutive entries before each jump, on the
; argument that a set entry is a contiguous sixteen bytes so ten of them are
; two and a half prefetchable cache lines.  Measured here the run only costs.
; See src/pyo/set.asm's probe for the numbers and the reason.

ENTRY_TOMBSTONE_HASH equ -1

; A set entry mirrors DictEntry minus the value: hash at +0, key Value at +8.
SET_ENTRY_HASH equ 0
SET_ENTRY_KEY  equ 8
SET_ENTRY_SIZE equ 16           ; the two fields above, and nothing else

; A set reuses the dict header but not its compact-layout words: dk_indices,
; dk_nentries and dk_kind mean nothing to a set.  The first of them is set's
; pop() cursor -- CPython calls it `finger` -- so draining a set does not
; rescan from slot zero on every call.  It is only ever a hint: it is masked
; before use, so a stale one costs a wrong starting slot and nothing more.
SET_FINGER equ 56               ; the word PyDictObject calls dk_indices

; The second is a frozenset's cached hash, -1 until something asks for it.
; CPython's PySetObject has the same field and the same sentinel, and a
; MUTABLE set simply leaves it at -1 forever -- which is what makes the
; O(1) inequality shortcut in set_richcompare need no type test: two sets
; whose cached hashes are both set and differ cannot be equal, and a set
; that never cached one never takes the shortcut.  frozenset_hash maps a
; computed -1 onto another constant so the sentinel stays unambiguous.
SET_HASH equ 64                 ; the word PyDictObject calls dk_nentries

; Set-entry counterpart of ENTRY_CLASSIFY.
%macro SET_ENTRY_CLASSIFY 3     ; %1 = entry ptr, %2 = empty label, %3 = tombstone label
    cmp qword [%1 + SET_ENTRY_KEY], 0
    jne %%occupied
    cmp qword [%1 + SET_ENTRY_HASH], ENTRY_TOMBSTONE_HASH
    je %3
    jmp %2
%%occupied:
%endmacro

; Classify a dict or set entry during a probe.  Jumps to %2 when the slot was
; never used (probing can stop) and to %3 when it holds a tombstone (probing
; must continue); falls through when the slot is occupied.
%macro ENTRY_CLASSIFY 3         ; %1 = entry ptr, %2 = empty label, %3 = tombstone label
    cmp qword [%1 + DictEntry.key], 0
    jne %%occupied
    cmp qword [%1 + DictEntry.hash], ENTRY_TOMBSTONE_HASH
    je %3
    jmp %2
%%occupied:
%endmacro

; Function object
struc PyFuncObject
    .ob_refcnt:     resq 1  ; +0
    .ob_type:       resq 1  ; +8
    .func_code:     resq 1  ; +16: ptr to code object
    .func_globals:  resq 1  ; +24: ptr to globals dict
    .func_name:     resq 1  ; +32: ptr to str object
    .func_defaults: resq 1  ; +40: ptr to defaults tuple or NULL
    .func_closure:  resq 1  ; +48: ptr to closure tuple or NULL
    .func_kwdefaults: resq 1 ; +56: ptr to kwdefaults dict or NULL
    .func_dict:     resq 1  ; +64: ptr to __dict__ or NULL (arbitrary attrs)
    .func_qualname: resq 1  ; +72: __qualname__, or NULL for co_qualname
    .func_doc:      resq 1  ; +80: __doc__, or NULL for co_consts[0].  Both are
                            ;      fields because CPython keeps them ON the
                            ;      function: f.__dict__ stays empty until
                            ;      something else is assigned, and
                            ;      functools.wraps sets exactly these two.
    ; +88: __annotations__.  MAKE_FUNCTION hands it over as a TUPLE of
    ; alternating name and value, which is what the compiler builds and what
    ; costs nothing when nobody asks; reading the attribute turns it into a
    ; dict and stores that back, so the conversion happens once.  NULL means
    ; the function was written without any, and reading it then makes an
    ; empty dict -- which CPython also stores, since `f.__annotations__['x']
    ; = int` has to stick.
    .func_annotations: resq 1
endstruc

; Code object
struc PyCodeObject
    .ob_refcnt:         resq 1  ; +0
    .ob_type:           resq 1  ; +8
    .co_argcount:       resd 1  ; +16
    .co_kwonlyargcount: resd 1  ; +20
    .co_nlocals:        resd 1  ; +24
    .co_stacksize:      resd 1  ; +28
    .co_flags:          resd 1  ; +32
    .co_nlocalsplus:    resd 1  ; +36
    .co_consts:         resq 1  ; +40: ptr to tuple
    .co_names:          resq 1  ; +48: ptr to tuple
    .co_localsplusnames: resq 1 ; +56: ptr to tuple
    .co_localspluskinds: resq 1 ; +64: ptr to bytes
    .co_filename:       resq 1  ; +72: ptr to str
    .co_name:           resq 1  ; +80: ptr to str
    .co_qualname:       resq 1  ; +88: ptr to str
    .co_exceptiontable: resq 1  ; +96: ptr to bytes
    .co_code_len:       resd 1  ; +104: bytecode length in bytes
    .co_posonlyargcount: resd 1 ; +108: positional-only arg count
    .co_firstlineno:    resd 1  ; +112: line of the `def`/module start
    .co_pad0:           resd 1  ; +116: (alignment)
    .co_linetable:      resq 1  ; +120: ptr to bytes (PEP 626 table) or NULL
    .co_code:                   ; +128: bytecode (variable)
endstruc

; The compiler self-modifies nothing, but the *interpreter* does: op_load_global
; writes eight bytes of inline cache at [rbx+2..rbx+7] and op_compare_op reads
; byte [rbx+2].  Either can run on the last instruction of a code object, so the
; bytecode allocation carries a zeroed tail so those reads and writes stay
; inside it.  co_code_len still records the true length.
CODE_TAIL_PAD equ 8

; Arguments to code_new().  There are too many fields for the SysV register set,
; so they arrive in one struct.  code_new STEALS every object reference in here;
; build into a zeroed CodeSpec on the stack and call code_spec_clear() to
; release the lot on any error path.
struc CodeSpec
    .code_bytes:      resq 1  ; +0:  const uint8_t* (borrowed; copied inline)
    .code_len:        resq 1  ; +8:  length in bytes
    .consts:          resq 1  ; +16: PyTupleObject*        (stolen)
    .names:           resq 1  ; +24: PyTupleObject*        (stolen)
    .localsplusnames: resq 1  ; +32: PyTupleObject*        (stolen)
    .localspluskinds: resq 1  ; +40: PyBytesObject* or 0   (stolen)
    .filename:        resq 1  ; +48: PyStrObject*          (stolen)
    .name:            resq 1  ; +56: PyStrObject*          (stolen)
    .qualname:        resq 1  ; +64: PyStrObject*          (stolen)
    .exceptiontable:  resq 1  ; +72: PyBytesObject* or 0   (stolen)
    .linetable:       resq 1  ; +80: PyBytesObject* or 0   (stolen)
    .argcount:        resd 1  ; +88
    .posonlyargcount: resd 1  ; +92
    .kwonlyargcount:  resd 1  ; +96
    .nlocals:         resd 1  ; +100: len(varnames) -- the true count, not nlocalsplus
    .stacksize:       resd 1  ; +104
    .flags:           resd 1  ; +108
    .firstlineno:     resd 1  ; +112
    .pad0:            resd 1  ; +116
endstruc

; Module object
struc PyModuleObject
    .ob_refcnt:   resq 1  ; +0
    .ob_type:     resq 1  ; +8
    .mod_name:    resq 1  ; +16: ptr to str
    .mod_dict:    resq 1  ; +24: ptr to module dict
endstruc

; Member descriptor object (for __slots__)
; PEP 585 generic alias: list[int].  _collections_abc takes GenericAlias from
; `type(list[int])`, and every annotation-bearing stdlib module needs it.
struc PyGenericAliasObject
    .ob_refcnt: resq 1  ; +0
    .ob_type:   resq 1  ; +8
    .ga_origin: resq 1  ; +16: the type being subscripted (owned)
    .ga_args:   resq 1  ; +24: the argument, a tuple if it was one (owned)
    ; PEP 646's `*tuple[int, str]`: iterating a GenericAlias yields one item,
    ; a copy of it with this set.  It reprs with a leading star, answers
    ; __unpacked__ True, and is what an annotation of that shape holds.
    .ga_starred: resq 1 ; +32
endstruc

; A getset descriptor: a named pair of C accessors living in a type's dict.
; CPython exposes func.__code__, code.co_name and friends this way, and
; types.py takes GetSetDescriptorType from one of them.
struc PyGetSetDescrObject
    .ob_refcnt: resq 1  ; +0
    .ob_type:   resq 1  ; +8
    .gs_get:    resq 1  ; +16: C getter(self) -> Value, or 0
    .gs_set:    resq 1  ; +24: C setter(self, value) -> int, or 0
    .gs_name:   resq 1  ; +32: ptr to the name (PyStrObject*, owned)
    .gs_owner:  resq 1  ; +40: the type it was registered on, or 0 -- for the
                        ;      repr, which CPython words "<attribute 'real'
                        ;      of 'int' objects>"; borrowed, types are static
    .gs_flags:  resq 1  ; +48: GS_* below
endstruc

; A getset whose getter is a whole tp_getattr rather than one attribute's:
; it is called (self, gs_name) and answers from the name.  Twelve of
; memoryview's attributes, and every one of property's, super's and the two
; method wrappers', are already answered by such a function; without this each
; would need a thunk of its own whose only content is the name it passes on.
GS_NAMED    equ 1

; A getset that stands for a slot in the instance LAYOUT rather than for
; something the class chose to keep: __dict__ and __weakref__, which type_new
; puts in the dict of very nearly every class.
;
; It is a data descriptor like any other getset, and attr_is_data_descr still
; says so -- that is what makes `o.__dict__` find it ahead of a stray instance
; entry, and what keeps LOAD_ATTR_INSTANCE from specialising the name into a
; plain dict read.  But it is in EVERY class's dict, so COUNTING it in
; TYPE_FLAG_MRO_HAS_DATA_DESCR would set that bit process-wide and force the
; descriptor-first attribute order on every class in the tree -- the one thing
; typecache.asm exists to avoid.
;
; The names it carries cannot reach an instance dict by any ordinary route, so
; the instance-dict-first order is also the CORRECT order for them; only
; dict_has_data_descr, which is that cached over-approximation, skips it.
GS_LAYOUT   equ 2

; types.SimpleNamespace: attributes are the entries of a dict.
struc PySimpleNamespaceObject
    .ob_refcnt: resq 1  ; +0
    .ob_type:   resq 1  ; +8
    .ns_dict:   resq 1  ; +16: the attribute dict (owned)
endstruc

; Read-only view of a mapping.  type.__dict__ is one of these in CPython,
; and types.py takes MappingProxyType from it.
struc PyMappingProxyObject
    .ob_refcnt: resq 1  ; +0
    .ob_type:   resq 1  ; +8
    .mp_mapping: resq 1 ; +16: the wrapped dict (owned)
endstruc

struc PyMemberDescrObject
    .ob_refcnt: resq 1  ; +0
    .ob_type:   resq 1  ; +8
    ; The byte offset of the slot within an instance.  NEGATIVE for a slot at
    ; the instance's TAIL, which is where a str subclass's go; SLOT_ADDR is
    ; the one place that knows.
    .md_offset: resq 1  ; +16
    .md_name:   resq 1  ; +24: ptr to slot name (PyStrObject*, owned)
    ; The class it was built for, borrowed -- the type owns the dict that
    ; owns this.  Only the repr reads it: "<member 'x' of 'S' objects>".
    .md_owner:  resq 1  ; +32
endstruc

; Class instance object
struc PyInstanceObject
    .ob_refcnt:   resq 1  ; +0
    .ob_type:     resq 1  ; +8  (type is the class)
    .inst_dict:   resq 1  ; +16: ptr to instance __dict__
endstruc

; Int subclass instance (class MyInt(int): ...)
struc PyIntSubclassObject
    .ob_refcnt:   resq 1  ; +0
    .ob_type:     resq 1  ; +8  (type is the subclass)
    .inst_dict:   resq 1  ; +16: ptr to instance __dict__
    .int_value:   resq 1  ; +24: the wrapped integer, as a Value
endstruc

; Iterator objects
struc PyListIterObject
    .ob_refcnt: resq 1    ; +0
    .ob_type:   resq 1    ; +8
    .it_seq:    resq 1    ; +16: ptr to list
    .it_index:  resq 1    ; +24: current index
endstruc

struc PyTupleIterObject
    .ob_refcnt: resq 1
    .ob_type:   resq 1
    .it_seq:    resq 1
    .it_index:  resq 1
endstruc

struc PyStrIterObject
    .ob_refcnt: resq 1    ; +0
    .ob_type:   resq 1    ; +8
    .it_seq:    resq 1    ; +16: ptr to str
    .it_index:  resq 1    ; +24: current byte index
endstruc

struc PyDictIterObject
    .ob_refcnt:  resq 1
    .ob_type:    resq 1
    .it_dict:    resq 1    ; +16: ptr to dict
    .it_index:   resq 1    ; +24: current entry index
    .it_kind:    resq 1    ; +32: 0=keys, 1=values, 2=items
    .it_version: resq 1    ; +40: the dict's SIZE when iteration began, which
                           ;      is what "changed size during iteration"
                           ;      means.  It held dk_version, which dict_set
                           ;      bumps for a rebind too -- a change that is
                           ;      not one.  The name is what CPython's
                           ;      di_used is for.
endstruc

struc PyDictViewObject
    .ob_refcnt: resq 1
    .ob_type:   resq 1
    .dv_dict:   resq 1    ; +16: ptr to dict (INCREF'd)
    .dv_kind:   resq 1    ; +24: 0=keys, 1=values, 2=items
endstruc

; A range holds its three bounds twice: as raw int64s, which every operation
; on an ordinary range uses, and as Values, which are what the bounds really
; are.  CPython's are objects, so `range(1 << 1000)` is an ordinary range
; there; the int64s cannot hold that, and .wide says so.  Every operation
; checks .wide and takes a slower path built on the Values when it is set.
; The three Values are OWNED references -- a wide bound is a heap int.
struc PyRangeObject
    .ob_refcnt: resq 1
    .ob_type:   resq 1
    .start:     resq 1    ; +16: start value (raw i64), exact unless .wide
    .stop:      resq 1    ; +24: stop value (raw i64), exact unless .wide
    .step:      resq 1    ; +32: step value (raw i64), exact unless .wide
    .vstart:    resq 1    ; +40: the same three as Values, always exact
    .vstop:     resq 1    ; +48
    .vstep:     resq 1    ; +56
    .wide:      resq 1    ; +64: 1 when a bound does not fit an int64
endstruc

struc PyRangeIterObject
    .ob_refcnt: resq 1
    .ob_type:   resq 1
    .it_current: resq 1   ; +16: current value
    .it_stop:    resq 1   ; +24: stop value
    .it_step:    resq 1   ; +32: step value
endstruc

; The iterator over a range whose bounds do not fit an int64.  CPython has a
; second type for exactly this case and calls it longrange_iterator, and
; type(iter(range(1 << 1000))) is how a program can tell.  The three fields
; are owned Values, and .it_len counts DOWN, as CPython's does: a wide range
; has no int64 length to compare against.
struc PyLongRangeIterObject
    .ob_refcnt: resq 1
    .ob_type:   resq 1
    .it_current: resq 1   ; +16: the next value to yield
    .it_step:    resq 1   ; +24
    .it_len:     resq 1   ; +32: how many are left
endstruc

struc PyBytesIterObject
    .ob_refcnt: resq 1
    .ob_type:   resq 1
    .it_seq:    resq 1    ; +16: ptr to bytes obj
    .it_index:  resq 1    ; +24: current index
endstruc

; Slice object
struc PySliceObject
    .ob_refcnt:   resq 1
    .ob_type:     resq 1
    .start:       resq 1    ; +16: Value
    .stop:        resq 1    ; +24: Value
    .step:        resq 1    ; +32: Value
endstruc

; Cell object (for closures)
struc PyCellObject
    .ob_refcnt: resq 1
    .ob_type:   resq 1
    .ob_ref:    resq 1    ; +16: contained Value (0 if empty)
endstruc

; super object (src/pyo/super.asm).  CPython's three fields, and the same
; names for them: __thisclass__ is where the MRO search starts FROM, __self__
; is the instance the result binds to, and __self_class__ is whose MRO is
; searched.  The third is not redundant -- it is the whole point of super in a
; diamond, where the class after B in type(self).__mro__ is a sibling of B and
; not one of its bases at all.
struc PySuperObject
    .ob_refcnt:   resq 1  ; +0
    .ob_type:     resq 1  ; +8
    .su_type:     resq 1  ; +16: __thisclass__, owned
    .su_obj:      resq 1  ; +24: __self__, owned, or 0 for super(B)
    .su_obj_type: resq 1  ; +32: __self_class__, owned, or 0
endstruc

; Bound method
struc PyMethodObject
    .ob_refcnt: resq 1
    .ob_type:   resq 1
    .im_func:   resq 1    ; +16: function
    .im_self:   resq 1    ; +24: instance
endstruc

; StaticMethod wrapper (descriptor)
struc PyStaticMethodObject
    .ob_refcnt:   resq 1  ; +0
    .ob_type:     resq 1  ; +8
    .sm_callable: resq 1  ; +16: wrapped function
endstruc

; ClassMethod wrapper (descriptor)
struc PyClassMethodObject
    .ob_refcnt:   resq 1  ; +0
    .ob_type:     resq 1  ; +8
    .cm_callable: resq 1  ; +16: wrapped function
endstruc

; Property descriptor
struc PyPropertyObject
    .ob_refcnt:   resq 1  ; +0
    .ob_type:     resq 1  ; +8
    .prop_get:    resq 1  ; +16: fget function or NULL
    .prop_set:    resq 1  ; +24: fset function or NULL
    .prop_del:    resq 1  ; +32: fdel function or NULL
    .prop_doc:    resq 1  ; +40: __doc__, a str or NULL.  It is a real field
                          ;      because it is WRITTEN: dis.py opens with
                          ;      `_Instruction.opname.__doc__ = "..."`, and a
                          ;      read-only __doc__ made that an AttributeError.
    .prop_name:   resq 1  ; +48: the attribute name, a str or NULL.  CPython
                          ;      learns it through __set_name__ and uses it in
                          ;      "property 'r' of 'C' object has no setter";
                          ;      without it the message was 3.10's wording.
endstruc

; Generator object
struc PyGenObject
    .ob_refcnt: resq 1
    .ob_type:   resq 1
    .gi_frame:  resq 1    ; +16: suspended frame
    .gi_running: resq 1   ; +24: 1 if currently executing
    .gi_code:   resq 1    ; +32: code object
    .gi_name:   resq 1    ; +40: name string
    .gi_return_value: resq 1 ; +48: return Value (for StopIteration.value)
    ; PEP 525's hooks, for an ASYNC generator only.  The firstiter hook fires
    ; once, the first time the generator is used, and the finalizer is
    ; snapshotted at that same moment -- so a generator collected after its
    ; event loop has moved on is still closed by the loop that started it,
    ; which is what CPython's ag_origin_or_finalizer does.
    .ag_hooks_done: resq 1   ; +56: 1 once firstiter has fired
    .ag_finalizer: resq 1    ; +64: the finalizer that was installed then, owned
    ; 1 once the body has been entered at least once.  gi_suspended is the
    ; difference between a generator stopped at a yield and one that has
    ; never run, and instr_ptr cannot tell them apart: it is non-zero for
    ; both and zero only once the generator is finished.
    .gi_started: resq 1      ; +72
endstruc

; File object (for sys.stdout, sys.stderr, sys.stdin)
; The buffer is what makes a redirected stdout arrive in blocks rather than a
; write per print(), which is CPython's behaviour and is observable: a program
; writing to both streams through a pipe sees ALL of its print() output after
; everything on stderr, because only one of the two is buffered.
FILE_BUFSZ equ 8192

struc PyFileObject
    .ob_refcnt:   resq 1  ; +0
    .ob_type:     resq 1  ; +8
    .file_fd:     resq 1  ; +16: OS file descriptor
    .file_name:   resq 1  ; +24: name string ('<stdout>' etc)
    .file_mode:   resq 1  ; +32: mode string ('w', 'r')
    .file_buffered: resq 1 ; +40: 1 = accumulate; 0 = one write per call
    .file_len:    resq 1  ; +48: bytes waiting in .file_buf
    .file_buf:    resb FILE_BUFSZ  ; +56
    ; The binary half this stream is a text layer over, built on first ask and
    ; kept.  sys.stdout is this object rather than a Python TextIOWrapper, so
    ; `sys.stdout.buffer` has nothing to hand back until something builds one;
    ; making it eagerly would mean importing _io at start-up, which costs
    ; 1.1 ms -> 2.9 ms on EVERY run.  Built lazily, only a program that asks
    ; pays.
    .file_binary: resq 1  ; owned, or 0
    ; Set by close(), read by `closed` and by every operation that touches
    ; the descriptor.  Without it close() shut the fd and left the object
    ; looking open, so a write afterwards went to a dead descriptor and the
    ; failure arrived at exit as "Exception ignored in: <stdout>" and an exit
    ; status of 120 -- which is what `apython -m json.tool` did, because
    ; json.tool writes through `with sys.stdout as out:`.
    .file_closed: resq 1
endstruc

; _io.FileIO.  The first three fields are PyInstanceObject's, because FileIO
; is a heaptype built with type_from_parts over _RawIOBase: instance_new
; allocates tp_basicsize and zero-fills, so the fields below start where the
; base's layout ends and cost nothing but a patched tp_basicsize.
struc PyFileIOObject
    .ob_refcnt:   resq 1  ; +0
    .ob_type:     resq 1  ; +8
    .inst_dict:   resq 1  ; +16: the tp_dictoffset _RawIOBase hands down
    .fio_fd:      resq 1  ; +24: the descriptor, meaningless unless FIO_OPEN
    .fio_flags:   resq 1  ; +32
    .fio_name:    resq 1  ; +40: the name as given, a Value -- an adopted
                          ;      descriptor makes it an int, not a str
    .fio_blksize: resq 1  ; +48: st_blksize, what readall() grows by
    .fio_mode:    resq 1  ; +56: the mode string, strong
endstruc

FIO_OPEN      equ 0x01
FIO_READABLE  equ 0x02
FIO_WRITABLE  equ 0x04
FIO_APPENDING equ 0x08
FIO_CREATED   equ 0x10
FIO_CLOSEFD   equ 0x20
; Whether seekability has been asked yet, and the answer.  One lseek settles
; it, and a pipe must answer False rather than raising every time.
FIO_SEEK_KNOWN equ 0x40
FIO_SEEKABLE   equ 0x80

; _io.BytesIO.  Laid out like PyFileIOObject and for the same reason: a
; heaptype over _BufferedIOBase whose tp_basicsize is patched, so the fields
; below sit past the instance header the base hands down.
struc PyBytesIOObject
    .ob_refcnt:   resq 1  ; +0
    .ob_type:     resq 1  ; +8
    .inst_dict:   resq 1  ; +16
    .bio_buf:     resq 1  ; +24: the storage, or 0 once closed
    .bio_size:    resq 1  ; +32: bytes written, which is what getvalue returns
    .bio_cap:     resq 1  ; +40: bytes allocated
    .bio_pos:     resq 1  ; +48: the read/write cursor
    .bio_exports: resq 1  ; +56: live getbuffer() views, which block a resize
endstruc

; Async task object (for event loop)
struc AsyncTask
    .ob_refcnt:    resq 1  ; +0
    .ob_type:      resq 1  ; +8
    .coro:         resq 1  ; +16: PyGenObject* (coroutine)
    .result:       resq 1  ; +24: result Value
    .pad_result:   resq 1  ; +32: (was result_tag)
    .exception:    resq 1  ; +40: exception or NULL
    ; +48 must line up with PyGenObject.gi_return_value: op_send reads that
    ; offset on whatever object a coroutine yielded, a task included.
    .send_value:   resq 1  ; +48: Value to send on next resume
    .pad_send:     resq 1  ; +56: (was send_tag)
    .done:         resd 1  ; +64: 0=pending, 1=done
    .cancelling:   resd 1  ; +68: 1=cancel requested
    .n_waiters:    resd 1  ; +72: number of waiters
    ; Whether this task is sitting in the ready queue.  ready_enqueue zeroes
    ; .next unconditionally, so enqueuing a task that is ALREADY queued
    ; truncated the list and lost everything behind it -- the loop then sat
    ; in wait_and_drain with nothing left to wake it.
    .queued:       resd 1  ; +76
    .waiters:      resq 1  ; +80: ptr to AsyncTask*[] array
    .waiters_cap:  resd 1  ; +88: waiters array capacity
    .pad2:         resd 1  ; +92
    .next:         resq 1  ; +96: ready queue linkage
    .ts_sec:       resq 1  ; +104: timespec seconds (for uring timeout SQE)
    .ts_nsec:      resq 1  ; +112: timespec nanoseconds
endstruc

; Sleep awaitable object (for asyncio.sleep)
; The awaitable _asynciocore.wait_fd() hands back: it yields the IO_WAIT
; sentinel once, which suspends the running task on the descriptor, and is
; exhausted after that.  The Python stream layer is built on it.
struc IOWaitAwaitable
    .ob_refcnt:  resq 1  ; +0
    .ob_type:    resq 1  ; +8
    .fd_events:  resq 1  ; +16: fd | (poll mask << 32), the sentinel payload
    .yielded:    resd 1  ; +24: 0 = not yet, 1 = done
    .pad:        resd 1  ; +28
endstruc

struc SleepAwaitable
    .ob_refcnt: resq 1  ; +0
    .ob_type:   resq 1  ; +8
    .delay_ns:  resq 1  ; +16
    .yielded:   resd 1  ; +24: 0=not yet, 1=done
    .pad:       resd 1  ; +28
endstruc

; asyncio.gather()'s awaitable.
;
; gather used to build one task per coroutine and hand back the LIST of them,
; with a TODO saying the awaiting was still to do -- so `await
; asyncio.gather(...)` awaited a list, which is not awaitable, and answered
; None.  This waits on each task in turn; every task is already enqueued, so
; they still run concurrently and the order only decides which one is
; observed first.
;
; +48 must line up with PyGenObject.gi_return_value: op_send reads that offset
; on the exhaustion path, the same reason WaitForAwaitable does.
struc GatherAwaitable
    .ob_refcnt:       resq 1  ; +0
    .ob_type:         resq 1  ; +8
    ; A plain ap_malloc'd AsyncTask*[], each entry owned, NOT a list: this
    ; object is not GC-visible, and a collection that ran while only this
    ; field referenced a list freed it under us.  Tasks are not collectable,
    ; so raw pointers to them are safe -- the same reason WaitForAwaitable
    ; keeps its inner_task raw.
    .ga_tasks:        resq 1  ; +16
    .ga_count:        resq 1  ; +24: how many
    .ga_index:        resq 1  ; +32: the task being waited on
    .ga_flags:        resq 1  ; +40: 1 = return_exceptions
    .gi_return_value: resq 1  ; +48: the results list, as a Value
    .ga_state:        resq 1  ; +56: 0 running, 1 finished
endstruc

; WaitFor awaitable object (for asyncio.wait_for)
struc WaitForAwaitable
    .ob_refcnt:       resq 1  ; +0
    .ob_type:         resq 1  ; +8
    .inner_task:      resq 1  ; +16: AsyncTask* being waited on
    .timeout_ns:      resq 1  ; +24: timeout in nanoseconds
    .state:           resd 1  ; +32: 0=init, 1=yielded, 2=done
    .pad:             resd 1  ; +36
    ; +40 is dead space, and has to stay: gi_return_value below must line up
    ; with PyGenObject's, which op_send reads without knowing which it has.
    ; It held an outer_task pointer that task_step wrote on every wait_for and
    ; nothing ever read -- a raw reference to a live task, for nothing.
    .unused:          resq 1  ; +40
    .gi_return_value: resq 1  ; +48: result Value (matches PyGenObject offset)
endstruc

; ReadAwaitable — awaitable for stream.read(n)
struc ReadAwaitable
    .ob_refcnt: resq 1  ; +0
    .ob_type:   resq 1  ; +8
    .fd:        resd 1  ; +16: socket fd
    .nbytes:    resd 1  ; +20: bytes to read
    .yielded:   resd 1  ; +24: 0=not yet, 1=done
    .pad:       resd 1  ; +28
endstruc

; WriteAwaitable — awaitable for stream.write(data)
struc WriteAwaitable
    .ob_refcnt: resq 1  ; +0
    .ob_type:   resq 1  ; +8
    .fd:        resd 1  ; +16: socket fd
    .pad1:      resd 1  ; +20
    .data:      resq 1  ; +24: string Value (INCREF'd)
    .yielded:   resd 1  ; +32: 0=not yet, 1=done
    .pad2:      resd 1  ; +36
endstruc

; DrainAwaitable — awaitable for stream.drain()
struc DrainAwaitable
    .ob_refcnt: resq 1  ; +0
    .ob_type:   resq 1  ; +8
    .fd:        resd 1  ; +16: socket fd
    .yielded:   resd 1  ; +20: 0=not yet, 1=done
endstruc

; AsyncGenASend — wrapper returned by async_gen.__anext__()
; SEND/tp_iternext on this object resumes the async gen.
; Layout must keep gi_return_value at +48, gi_return_tag at +56
; because op_send reads these offsets from the receiver on exhaustion.
;; The box CALL_INTRINSIC_1 INTRINSIC_ASYNC_GEN_WRAP puts around a value an
;; async generator yields.  An async generator's frame yields for two different
;; reasons -- an item for its consumer, and an `await` passing through to the
;; event loop -- and this box is the only thing that tells them apart.
struc AsyncGenWrapped
    .ob_refcnt:     resq 1  ; +0
    .ob_type:       resq 1  ; +8
    .agw_value:     resq 1  ; +16: the wrapped Value, owned
endstruc

struc AsyncGenASend
    .ob_refcnt:     resq 1  ; +0
    .ob_type:       resq 1  ; +8
    .ags_gen:       resq 1  ; +16: pointer to async generator (INCREF'd)
    .ags_state:     resd 1  ; +24: 0=initial, 1=yielded, 2=closed
    .ags_aclose:    resd 1  ; +28: 1 when this athrow came from aclose() rather
                            ;      than athrow(exc).  CPython tells them apart
                            ;      by whether agt_args is NULL, which it never
                            ;      clears; ags_sendval IS cleared when the throw
                            ;      is delivered, so the mode needs its own word
    .ags_sendval:   resq 1  ; +32: the Value asend.send() will resume with,
                            ;      owned, 0 for None
    .ags_started:   resd 1  ; +40: athrow only -- 1 once the throw has been
                            ;      delivered, so a later drive resumes instead
    .pad2:          resd 1  ; +44
    .gi_return_value: resq 1 ; +48: yielded Value (for SEND exhaustion path)
endstruc

; Sentinel values

;; ============================================================================
;; Type objects: PyTypeObject and the three method tables
;; (was include/types.inc)
;; ============================================================================

; Type object layout
struc PyTypeObject
    .ob_refcnt:      resq 1  ; +0
    .ob_type:        resq 1  ; +8  (metatype, usually &type_type)
    .tp_name:        resq 1  ; +16  ptr to C string
    .tp_basicsize:   resq 1  ; +24
    .tp_dealloc:     resq 1  ; +32  function ptr
    .tp_repr:        resq 1  ; +40  function ptr
    .tp_str:         resq 1  ; +48  function ptr (defaults to tp_repr if NULL)
    .tp_hash:        resq 1  ; +56  function ptr
    .tp_call:        resq 1  ; +64  function ptr
    .tp_getattr:     resq 1  ; +72  function ptr
    .tp_setattr:     resq 1  ; +80  function ptr
    .tp_richcompare: resq 1  ; +88  function ptr
    .tp_iter:        resq 1  ; +96  function ptr
    .tp_iternext:    resq 1  ; +104 function ptr
    .tp_init:        resq 1  ; +112 function ptr
    .tp_new:         resq 1  ; +120 function ptr
    .tp_as_number:   resq 1  ; +128 ptr to number methods or NULL
    .tp_as_sequence: resq 1  ; +136 ptr to sequence methods or NULL
    .tp_as_mapping:  resq 1  ; +144 ptr to mapping methods or NULL
    .tp_base:        resq 1  ; +152 ptr to base type
    .tp_dict:        resq 1  ; +160 ptr to type's __dict__
    .tp_mro:         resq 1  ; +168 ptr to MRO tuple
    .tp_flags:       resq 1  ; +176
    .tp_bases:       resq 1  ; +184 ptr to bases tuple
    .tp_traverse:    resq 1  ; +192 GC traverse function ptr
    .tp_clear:       resq 1  ; +200 GC clear function ptr
    ; Byte offset of the instance __dict__ within an instance, or 0 for a
    ; type whose instances have none.  Only ever read for a heaptype, which
    ; is gc_alloc'd and zero-filled, so a static table that predates this
    ; field cannot be misread.
    .tp_dictoffset:  resq 1  ; +208
    ; How many __slots__ words live at the TAIL of an instance, past the data
    ; and past the tail dict word.  Only a str subclass has any: it keeps its
    ; characters inline, so there is no fixed offset past the header to lay a
    ; slot at -- one put there writes over the string's own bytes.  The count
    ; is cumulative, so a subclass's own slots start at its base's count, and
    ; a member descriptor addresses one with a NEGATIVE md_offset.  Zero for
    ; every other type, which is what a static table that predates the field
    ; reads as.
    .tp_tailslots:   resq 1  ; +216
    ; How to reach an object's raw bytes: CPython's tp_as_buffer, reduced to
    ; the one question everything here asks -- "where is the memory and how
    ; much of it is there".  bytes_like_ptr_len consults it when its own
    ; hard-coded chain misses, which is what lets memoryview(), bytes(),
    ; FileIO.write, marshal, sre and the twenty-odd bytes methods take an
    ; array, or any exporter added later, without each learning the type by
    ; name.
    ;
    ; The signature is
    ;     tp_getbuffer(rdi = obj, esi = BUF_GET) -> rax = data ptr,
    ;                                rdx = length in BYTES,
    ;                                ecx = 1 when it answered, 0 when not
    ; so a type whose buffer can be absent -- a released memoryview -- says so
    ; without raising, which is the contract bytes_like_ptr_len already keeps.
    ;
    ; BUF_ACQUIRE and BUF_RELEASE are the accounting a LASTING view needs, and
    ; they answer nothing.  A view keeps the POINTER, and an exporter's storage
    ; can move -- an array's does, when it grows -- so an exporter has to be
    ; able to refuse a resize while someone holds one.  CPython splits this
    ; across bf_getbuffer and bf_releasebuffer; one slot answers all three here.
    ; A caller that only reads the bytes and is done with them before any other
    ; code runs passes BUF_GET alone, which is what every caller of
    ; bytes_like_ptr_len does.
    ;
    ; BUF_GETINFO is what a memoryview needs and a byte reader does not:
    ;     tp_getbuffer(rdi = obj, esi = BUF_GETINFO)
    ;       -> rax = a struct format cstr, or 0 to take the defaults
    ;          rdx = the item size in bytes
    ;          ecx = 1 when the buffer may be written through
    ; Answering 0 keeps what memoryview assumed of every exporter before this
    ; mode existed -- one-byte items, format "B", read-only -- so an exporter
    ; that does not implement it is unaffected.  Without it
    ; `memoryview(array("i", [1, 2, 3]))` had itemsize 1, format "B", length
    ; 12 and tolist() of the twelve bytes.
    .tp_as_buffer:   resq 1  ; +224
endstruc

BUF_GET     equ 0
BUF_ACQUIRE equ 1
BUF_RELEASE equ 2
BUF_GETINFO equ 3

TYPE_OBJECT_SIZE equ PyTypeObject_size

; Two words past the type, for a HEAPTYPE only -- a static type's table ends at
; tp_tailslots and nothing reads past it.
;
; The first is where a struct sequence keeps its descriptor (STRUCTSEQ_DESC,
; below), so a class that derives from one finds it where it looks; the second
; is CPython's ht_qualname.  __qualname__ cannot stay in tp_dict: it is a
; getset on `type` in CPython, so `'__qualname__' in C.__dict__` is False
; there and an INSTANCE of C cannot see it -- and here every instance of every
; class answered its class's, and vars(C) had an entry CPython's does not.
HT_QUALNAME        equ PyTypeObject_size + 8
HEAPTYPE_ALLOC_SIZE equ PyTypeObject_size + 16

; Number methods structure
struc PyNumberMethods
    .nb_add:           resq 1  ; +0
    .nb_subtract:      resq 1  ; +8
    .nb_multiply:      resq 1  ; +16
    .nb_remainder:     resq 1  ; +24
    .nb_divmod:        resq 1  ; +32
    .nb_power:         resq 1  ; +40
    .nb_negative:      resq 1  ; +48
    .nb_positive:      resq 1  ; +56
    .nb_absolute:      resq 1  ; +64
    .nb_bool:          resq 1  ; +72
    .nb_invert:        resq 1  ; +80
    .nb_lshift:        resq 1  ; +88
    .nb_rshift:        resq 1  ; +96
    .nb_and:           resq 1  ; +104
    .nb_xor:           resq 1  ; +112
    .nb_or:            resq 1  ; +120
    .nb_int:           resq 1  ; +128
    .nb_float:         resq 1  ; +136
    .nb_floor_divide:  resq 1  ; +144
    .nb_true_divide:   resq 1  ; +152
    .nb_index:         resq 1  ; +160
    ; Inplace slots (used by NB_INPLACE_* opcodes)
    .nb_iadd:          resq 1  ; +168
    .nb_isub:          resq 1  ; +176
    .nb_imul:          resq 1  ; +184
    .nb_irem:          resq 1  ; +192
    .nb_ipow:          resq 1  ; +200
    .nb_ilshift:       resq 1  ; +208
    .nb_irshift:       resq 1  ; +216
    .nb_iand:          resq 1  ; +224
    .nb_ixor:          resq 1  ; +232
    .nb_ior:           resq 1  ; +240
    .nb_ifloor_divide: resq 1  ; +248
    .nb_itrue_divide:  resq 1  ; +256
    ; The @ operator.  These were missing entirely, and binary_op_offsets
    ; mapped NB_MATRIX_MULTIPLY to offset 0 -- which is nb_add -- so 3 @ 4
    ; silently returned 7.
    .nb_matmul:        resq 1  ; +264
    .nb_imatmul:       resq 1  ; +272
endstruc

; Sequence methods structure
struc PySequenceMethods
    .sq_length:        resq 1  ; +0
    .sq_concat:        resq 1  ; +8
    .sq_repeat:        resq 1  ; +16
    .sq_item:          resq 1  ; +24
    .sq_ass_item:      resq 1  ; +32
    .sq_contains:      resq 1  ; +40
    .sq_inplace_concat: resq 1 ; +48
    .sq_inplace_repeat: resq 1 ; +56
endstruc

; Mapping methods structure
struc PyMappingMethods
    .mp_length:        resq 1  ; +0
    .mp_subscript:     resq 1  ; +8
    .mp_ass_subscript: resq 1  ; +16
endstruc

; Linux x86-64 `struct stat`, as the stat/lstat/fstat syscalls fill it.
; STAT_SIZE and a couple of the offsets were copied privately into
; src/marshal.asm, src/compiler/compile.asm and inline into
; src/builtins_obj.asm; posix reads nearly all of them.
;
; st_uid and st_gid are 32-bit and st_mode is too -- a 64-bit read of any of
; the three silently ORs in its neighbour, which is the trap CLAUDE.md names.
struc StatBuf
    .st_dev:        resq 1  ; +0
    .st_ino:        resq 1  ; +8
    .st_nlink:      resq 1  ; +16
    .st_mode:       resd 1  ; +24  (32-bit)
    .st_uid:        resd 1  ; +28  (32-bit)
    .st_gid:        resd 1  ; +32  (32-bit)
    .st_pad0:       resd 1  ; +36
    .st_rdev:       resq 1  ; +40
    .st_size:       resq 1  ; +48
    .st_blksize:    resq 1  ; +56
    .st_blocks:     resq 1  ; +64
    .st_atime:      resq 1  ; +72
    .st_atime_ns:   resq 1  ; +80
    .st_mtime:      resq 1  ; +88
    .st_mtime_ns:   resq 1  ; +96
    .st_ctime:      resq 1  ; +104
    .st_ctime_ns:   resq 1  ; +112
    .st_unused:     resq 3  ; +120
endstruc                    ; 144 bytes

; open() flags, as <fcntl.h> has them on Linux.  builtin_open_fn hardcoded
; 0x241, 0x441 and 0xc1 inline.
O_RDONLY    equ 0o0
O_WRONLY    equ 0o1
O_RDWR      equ 0o2
O_ACCMODE   equ 0o3
O_CREAT     equ 0o100
O_EXCL      equ 0o200
O_NOCTTY    equ 0o400
O_TRUNC     equ 0o1000
O_APPEND    equ 0o2000
O_NONBLOCK  equ 0o4000
O_DIRECTORY equ 0o200000
O_NOFOLLOW  equ 0o400000
O_CLOEXEC   equ 0o2000000
; O_TMPFILE is two bits, and both of them: Linux spells it
; __O_TMPFILE | O_DIRECTORY so that an old kernel, which honours only
; the directory bit, refuses the open rather than creating a file.
__O_TMPFILE equ 0o20000000
O_TMPFILE   equ __O_TMPFILE | O_DIRECTORY

; access() modes
F_OK equ 0
X_OK equ 1
W_OK equ 2
R_OK equ 4

; lseek() whence
SEEK_SET equ 0
SEEK_CUR equ 1
SEEK_END equ 2

; st_mode's file-type field, and the mask that selects it.
S_IFMT   equ 0o170000
S_IFSOCK equ 0o140000
S_IFLNK  equ 0o120000
S_IFREG  equ 0o100000
S_IFBLK  equ 0o060000
S_IFDIR  equ 0o040000
S_IFCHR  equ 0o020000
S_IFIFO  equ 0o010000

; linux_dirent64, the record getdents64 writes.  d_reclen is the stride to the
; next record and is TWO bytes: a 64-bit read of it ORs in d_type and five
; bytes of the name, which is exactly the multi-gigabyte-memcpy bug CLAUDE.md
; records.  lint.py derives widths from `resd` and so does not catch a `resw`.
; posix.DirEntry -- one directory entry, as scandir() hands it back.  It keeps
; what getdents64 already told us (the name and d_type) so the ordinary
; is_dir()/is_file() questions cost no syscall at all, which is the whole point
; of scandir over listdir + stat.
struc PyDirEntryObject
    .ob_refcnt: resq 1      ; +0
    .ob_type:   resq 1      ; +8
    .de_name:   resq 1      ; +16: PyStrObject*, owned
    .de_path:   resq 1      ; +24: PyStrObject*, owned -- the scandir argument
                            ;      joined to the name, which is what .path is
    .de_type:   resq 1      ; +32: d_type from the dirent, DT_UNKNOWN if the
                            ;      filesystem did not say
    .de_ino:    resq 1      ; +40: d_ino, what .inode() answers
endstruc

; The iterator scandir() returns.  It holds the entries it has already built --
; the directory is read in one pass, where CPython reads it lazily -- and a
; context manager's close() drops them.
struc PyScandirIterObject
    .ob_refcnt: resq 1      ; +0
    .ob_type:   resq 1      ; +8
    .sd_list:   resq 1      ; +16: PyListObject* of DirEntry, owned; 0 = closed
    .sd_index:  resq 1      ; +24
endstruc

struc LinuxDirent64
    .d_ino:    resq 1   ; +0
    .d_off:    resq 1   ; +8
    .d_reclen: resw 1   ; +16  (16-bit -- the stride)
    .d_type:   resb 1   ; +18
    .d_name:            ; +19, NUL-terminated
endstruc

; Linux's `struct utsname`: six fixed 65-byte NUL-terminated fields.  os.uname()
; exposes the first five; the sixth, domainname, is a GNU extension CPython
; does not report.
UTSNAME_FIELD equ 65
UTSNAME_SIZE  equ 65 * 6

; ioctl request numbers
TCGETS equ 0x5401

; fcntl commands, for the close-on-exec flag os.set_inheritable moves
F_GETFD    equ 1
F_SETFD    equ 2
FD_CLOEXEC equ 1

; d_type values
DT_UNKNOWN equ 0
DT_FIFO    equ 1
DT_CHR     equ 2
DT_DIR     equ 4
DT_BLK     equ 6
DT_REG     equ 8
DT_LNK     equ 10
DT_SOCK    equ 12

; waitpid() options, and the encoding of the status word it fills in.
WNOHANG   equ 1
WUNTRACED equ 2
WCONTINUED equ 8

; A struct sequence: a tuple whose entries are also named (os.stat_result,
; sys.version_info).  The descriptor hangs off the end of the type -- one
; qword just past PyTypeObject -- so tp_getattr, tp_repr and tp_dealloc can
; each find their own from the instance's type instead of needing a thunk.
struc StructSeqField
    .name:  resq 1          ; +0: NUL-terminated C string
    .index: resq 1          ; +8: below n_in_sequence => ob_item[index];
endstruc                    ;     at or above it => the (index - n) tail slot

struc StructSeqDesc
    .n_in_sequence: resq 1  ; +0: the tuple's length, NOT the field count
    .n_fields:      resq 1  ; +8: including the named-only tail
    .fields:        resq 1  ; +16: -> StructSeqField[n_fields]
endstruc

; The descriptor's offset within a struct-sequence type object.
STRUCTSEQ_DESC equ PyTypeObject_size

; One row of builtin_module_table (src/modtable.asm): a module compiled into
; the interpreter.  Both sys.modules and sys.builtin_module_names are built
; from it, so the two cannot drift apart again.
struc BuiltinModule
    .name:      resq 1      ; +0: NUL-terminated C string
    .create_fn: resq 1      ; +8: PyObject *(*)(void), or 0 when import_init
endstruc                    ;     wires that module some other way

; The number of rows is computed in modtable.asm as builtin_module_count and
; loaded from there.  It was an equ here, and adding a module without editing
; it truncated the table.

; Type flags
; The direct-subclass side table's per-base record, in src/pyo/subclasses.asm.
; The table itself is private to that file; the layout is here because
; type_refresh_getattribute_flag walks it to push an inherited answer down.
struc SubList
    .count:    resq 1
    .capacity: resq 1
    .items:    resq 1       ; ap_malloc'd PyTypeObject*[capacity]
endstruc

TYPE_FLAG_HEAPTYPE     equ 0x0001
TYPE_FLAG_BASETYPE     equ 0x0002
TYPE_FLAG_HAVE_GC      equ 0x0004
; Some type in this type's MRO defines a __getattribute__ of its own.  Negative
; sense on purpose: object supplies one that every class inherits, so "has an
; entry" is true everywhere and useless -- what instance_getattr needs to know
; is whether the entry is anything OTHER than object's.
;
; instance_getattr used to ask that question with a full MRO walk on EVERY
; attribute access, which measured 20-37% of the instructions in
; attribute-heavy code.  The answer only changes when a type in the MRO is
; written to, so it is computed at class creation and refreshed by
; type_setattr -- down through every subclass, since the answer is inherited.
TYPE_FLAG_GETATTRIBUTE_OVERRIDDEN equ 0x0008
; Some type in this type's MRO keeps a DATA descriptor -- a property, a
; __slots__ member, a getset, or anything whose own type defines __set__ or
; __delete__ -- in its dict.
;
; A data descriptor outranks the instance dict, and a non-data one does not.
; Resolving that needs the MRO consulted BEFORE the instance dict, which is
; the opposite of the order that is fast: an ordinary `self.x` wants the
; instance dict hit on the first lookup.  The bit says which order is correct,
; so a class with no data descriptors -- almost all of them -- keeps the fast
; one.  Maintained beside TYPE_FLAG_GETATTRIBUTE_OVERRIDDEN.
TYPE_FLAG_MRO_HAS_DATA_DESCR equ 0x0010
TYPE_FLAG_INT_SUBCLASS equ 0x0100
TYPE_FLAG_STR_SUBCLASS equ 0x0200
TYPE_FLAG_LIST_SUBCLASS equ 0x0400
TYPE_FLAG_TUPLE_SUBCLASS equ 0x0800
TYPE_FLAG_DICT_SUBCLASS equ 0x1000
TYPE_FLAG_SET_SUBCLASS equ 0x4000   ; 0x2000 is TYPE_FLAG_HAS_SLOTS
TYPE_FLAG_HAS_SLOTS     equ 0x2000
; Instances of this type are classes.  "Is this object a class?" used to be
; asked as `ob_type is user_type_metatype`, which is false for a class built by
; a metaclass of its own -- so a classmethod reached through such a class bound
; the metaclass instead of the class.
TYPE_FLAG_METATYPE      equ 0x8000
; float and complex keep their value inline, exactly as int and str do, so a
; subclass cannot come from instance_new either -- it has to be built by the
; base's own constructor, and every conversion helper has to recognise it.
; The low nibble range is full; these two start the next one.
TYPE_FLAG_FLOAT_SUBCLASS   equ 0x10000
TYPE_FLAG_COMPLEX_SUBCLASS equ 0x20000
; bytearray keeps its bytes in a separate allocation, so a subclass instance
; owns memory the generic instance_dealloc knows nothing about.
TYPE_FLAG_BYTEARRAY_SUBCLASS equ 0x40000
; bytes keeps its data inline as str does, so a subclass instance is a pointer
; whose ob_type is not bytes_type.  Without a flag for it BINOP_REQUIRE_LEFT
; was given a literal 0 at bytes' two arithmetic slots, and every `+` and `*`
; on a bytes subclass declined into a TypeError.
TYPE_FLAG_BYTES_SUBCLASS equ 0x80000

; A type CPython refuses to let you subclass -- the ones without
; Py_TPFLAGS_BASETYPE.  It is the inverse of CPython's flag on purpose: every
; type here is subclassable unless it says otherwise, so adding the flag to a
; handful is a change of four lines rather than an audit of ninety-four
; tables, and a type object that predates it reads as subclassable, which is
; what it was.
TYPE_FLAG_FINAL          equ 0x100000

; Does anything in this type's MRO have an entry named __del__?  ANY entry:
; the bit stands in for "dunder_lookup finds something", not for "and it is
; callable", so `__del__ = None` still reaches dunder_call_1 and still reports
; 'NoneType' object is not callable the way it did.  Maintained beside
; TYPE_FLAG_GETATTRIBUTE_OVERRIDDEN and TYPE_FLAG_MRO_HAS_DATA_DESCR by
; type_refresh_attr_flags, so it is recomputed and pushed down every subclass
; whenever a class dict is written.
;
; instance_dealloc asked by NAME instead, on every heaptype instance that
; died: a dunder_call_1, which is an MRO walk and a dict probe per entry, to
; discover that a class almost never has one.  Callgrind put it at 23.9% of a
; `class C: pass` construction loop.  Every heaptype comes from
; type_from_parts, which calls the refresh, so the bit is always current.
TYPE_FLAG_HAS_DEL        equ 0x200000

; The type's instances are AWAITABLE through tp_iter -- CPython's
; tp_as_async->am_await, which this tree has no slot for.  GET_AWAITABLE and
; GET_ANEXT fall back to tp_iter for the awaitables the interpreter builds
; for itself, and without a marker that fallback accepted every ORDINARY
; iterable too: `__anext__` returning an empty tuple made `async for` spin
; for ever, because the tuple's iterator is a perfectly good iterator.
TYPE_FLAG_AWAITABLE      equ 0x400000

; The class body declared __slots__ -- ANY __slots__, including one that names
; '__dict__' and so keeps the instance dict.
;
; TYPE_FLAG_HAS_SLOTS is not that question: it means "this class has no instance
; dict", which a __slots__ naming '__dict__' leaves clear, and a __slots__ on a
; class whose base already supplies a dict leaves clear too.
; weakref_referenceable asked HAS_SLOTS and so read such a class as slot-free,
; making its instances weak-referenceable where CPython refuses them -- naming
; '__dict__' does not excuse a __slots__ from suppressing the weakref word.
TYPE_FLAG_DECLARED_SLOTS equ 0x800000

; A STATIC type whose tp_dict defines __get__, so an instance of it found in a
; class dict is a descriptor and has to be bound on the way out.
;
; The attribute paths ask "is this a descriptor?" by looking __get__ up on the
; attribute's own type, and they gate that lookup on TYPE_FLAG_HEAPTYPE --
; every builtin descriptor that matters (property, getset, classmethod,
; staticmethod, function) is special-cased by identity above it, so the
; general arm exists for user-written ones and the gate keeps an ordinary
; `C.x = 3` from paying a dict probe.  `super` is the one builtin that is a
; descriptor and is NOT special-cased: `C._C__super = super(C)` then
; `self.__super.meth()` read the unbound super straight back.  This bit opens
; the same arm for it, and for anything else that grows a __get__ later,
; without widening the gate to every static type.
TYPE_FLAG_DESCRIPTOR     equ 0x1000000

; TYPE_FLAG_MRO_HAS_DATA_DESCR narrowed to the HEAPTYPES of the MRO: some class
; written in Python, in this type's MRO, keeps something that may be a data
; descriptor in its dict.  The same over-approximation, from the same scan.
;
; Read on a METATYPE.  A data descriptor on a class's metaclass outranks the
; class's own dict, but `type`'s getsets -- in every metaclass's MRO, so the
; wide flag is set on all of them -- are answered by type_getattr_meta's
; ladder already.  What is left to look for is only ever in a metaclass the
; user wrote, and this bit says whether there is one, so a class made by
; ABCMeta or EnumType pays nothing for the check either.
TYPE_FLAG_HEAP_DATA_DESCR equ 0x2000000

; The type's VERSION lives in the high 32 bits of tp_flags, which the flags
; above leave free -- they stop at bit 25.  It is a stamp from one global
; counter, so a version identifies a particular type in a particular state of
; its dict, and comparing one is both "the same class" and "nothing has been
; added to it or to anything in its MRO since".
;
; The alternative was a new PyTypeObject field, and it is worse than it looks:
; STRUCTSEQ_DESC hangs a struct-sequence descriptor one qword past the end of
; the struct, and 94 static type tables are hand-written `dq` sequences that
; would each need a new trailing word or read whatever symbol follows.
;
; ZERO MEANS NEVER CACHE.  A static type's hand-written table has zeroes there
; and never gets a version, which is correct rather than merely safe: its
; instances have no instance dict, so the caches that read this do not apply
; to them.  type_bump_version skips zero on wraparound, as dk_version does.
TYPE_VERSION_SHIFT equ 32

; Comparison opcodes (used by tp_richcompare)
PY_LT equ 0
PY_LE equ 1
PY_EQ equ 2
PY_NE equ 3
PY_GT equ 4
PY_GE equ 5

;; ============================================================================
;; PyFrame
;; (was include/frame.inc)
;; ============================================================================

; Execution frame layout
struc PyFrame
    .prev_frame:    resq 1  ; +0:  ptr to previous frame
    .code:          resq 1  ; +8:  ptr to code object
    .globals:       resq 1  ; +16: ptr to globals dict
    .builtins:      resq 1  ; +24: ptr to builtins dict
    .locals:        resq 1  ; +32: ptr to locals dict (or NULL for fast locals)
    .instr_ptr:     resq 1  ; +40: saved bytecode pointer
    .stack_ptr:     resq 1  ; +48: saved value stack pointer
    .stack_base:    resq 1  ; +56: ptr to bottom of the value stack
    ; How many PUSH_EXC_INFOs this frame has executed and not yet popped.
    ; Zero means the frame is handling nothing of its own and merely SHARES
    ; its caller's exception; anything else means it has one, and .exc_state
    ; below is where eval_return parks it.  Only a generator or coroutine can
    ; suspend with this non-zero, which is the whole reason it is on the frame
    ; and not in a register.  (This word was .return_offset, written once by
    ; frame_new and never read.)
    .exc_depth:     resd 1  ; +64: unpopped PUSH_EXC_INFO count
    .nlocalsplus:   resd 1  ; +68: number of locals + cells + frees
    .func_obj:      resq 1  ; +72: ptr to function object (for closures)
    .call_ip:       resq 1  ; +80: where this frame was when it called into
                            ;      the next one -- what f_lineno reads for a
                            ;      frame that is not the innermost.  instr_ptr
                            ;      cannot carry it: non-zero there means the
                            ;      frame is SUSPENDED, and func_call reads it
                            ;      to decide whether to free the frame.
    .exc_state:     resq 1  ; +88: the exception this frame is HANDLING while
                            ;      it is suspended, owned, or 0.  Only a
                            ;      generator or coroutine ever has one: an
                            ;      ordinary frame shares the caller's, which
                            ;      is what handled_exception already holds,
                            ;      and returns before anything else can run.
                            ;      gen_send swaps it with the global around
                            ;      each resume -- CPython's gi_exc_state.
    .frame_obj:     resq 1  ; +96: the PyFrameObject looking at this frame,
                            ;      BORROWED, or 0.  It is what makes
                            ;      sys._getframe() answer the same object
                            ;      twice and lets a trace function write
                            ;      f_trace back -- bdb compares frames by
                            ;      identity across events.  Three places must
                            ;      agree it is borrowed: frame_new zeroes it
                            ;      (the pool does not), frame_free detaches,
                            ;      and frameobj_dealloc clears it.
    .gen_owner:     resq 1  ; +104: the generator or coroutine whose frame this
                            ;      is, BORROWED, or 0 for an ordinary call.
                            ;      frame.clear() needs it: closing a suspended
                            ;      generator from the outside means reaching
                            ;      the generator, and a frame object only has
                            ;      the frame.  Borrowed because the generator
                            ;      owns the frame, not the other way round.
    ; How this frame was entered, and therefore how it is left.  Zero is a
    ; C-level `call eval_frame` -- a module body, an eval(), a class body, a
    ; generator resume, func_call's slow path -- and eval_return leaves such a
    ; frame with a `ret`.  Anything else means a bytecode handler pushed the
    ; frame INLINE and there is no `ret` to go back to: eval_return restores
    ; the caller and jumps to that handler's resume instead.  .entry_slots is
    ; the resume's one piece of state, the value-stack slots the call
    ; consumed, and it has to be read out of the frame before it is freed.
    .entry_kind:    resd 1  ; +112: FRAME_ENTRY_*
    .entry_slots:   resd 1  ; +116: inline only
    .localsplus:            ; +120: Value array (variable size)
endstruc

FRAME_ENTRY_CALL   equ 0    ; entered by `call eval_frame`; left by `ret`
FRAME_ENTRY_INLINE equ 1    ; pushed by CALL_PY_EXACT; left by eval_inline_resume

; The frame pool: four size classes, each a singly-linked freelist whose next
; link lives in the block's first word, capped so a burst of deep recursion
; does not park megabytes there for ever.  A pool record is (head, count),
; selected as a unit with `lea rcx, [rel frame_pool_free_N]` and then indexed.
;
; They are here rather than in src/frame.asm because the specialized call
; pops the smallest class inline -- that is the size of nearly every frame,
; and going through frame_pool_get for it is a call, a size ladder and a
; return.  Everything else, including every push back, is still frame.asm's.
FRAME_POOL_CLASS_0  equ 256
FRAME_POOL_CLASS_1  equ 512
FRAME_POOL_CLASS_2  equ 1024
FRAME_POOL_CLASS_3  equ 2048
FRAME_POOL_MAX_FREE equ 16
FRAME_POOL_HEAD     equ 0
FRAME_POOL_COUNT    equ 8

FRAME_HEADER_SIZE equ PyFrame.localsplus

; The snapshot sys._getframe() hands back.  A PyFrame is pooled and recycled,
; so an object holding one would be looking at a later call's frame; this
; copies what a caller can read and outlives the frames.
struc PyFrameObject
    .ob_refcnt:   resq 1  ; +0
    .ob_type:     resq 1  ; +8
    .f_back:      resq 1  ; +16: the next snapshot outward, owned, or 0
    .f_code:      resq 1  ; +24
    .f_globals:   resq 1  ; +32
    .f_locals:    resq 1  ; +40
    .f_builtins:  resq 1  ; +48
    .f_lineno:    resq 1  ; +56: where the frame was when the snapshot ran,
                          ;      or, for a live one, recomputed on every read
    .f_lasti:     resq 1  ; +64: a BYTE offset into co_code, as CPython's is
    .f_frame:     resq 1  ; +72: the live PyFrame this is a view onto,
                          ;      BORROWED, or 0 once it has been detached.
                          ;      Zero from the start for a snapshot -- a
                          ;      traceback entry's frame is long gone.
    .f_trace:     resq 1  ; +80: the local trace function, owned, or 0
    .f_trace_lines:   resq 1  ; +88: 1 by default, as CPython's is
    .f_trace_opcodes: resq 1  ; +96: 0 by default
    .ft_line:     resq 1  ; +104: the line last reported to the tracer, or -1.
                          ;       A 'line' event fires when the line CHANGES,
                          ;       or on any backward jump; these two words are
                          ;       what "changes" is measured against, and both
                          ;       reset at frame entry and at generator resume
    .ft_prev:     resq 1  ; +112: the offset last executed, in code units
endstruc

;; ============================================================================
;; Exceptions, tracebacks, and the fatal error codes
;; (was include/errcodes.inc)
;; ============================================================================

; Exception type IDs
EXC_BASE_EXCEPTION     equ 0
EXC_EXCEPTION          equ 1
EXC_TYPE_ERROR         equ 2
EXC_VALUE_ERROR        equ 3
EXC_KEY_ERROR          equ 4
EXC_INDEX_ERROR        equ 5
EXC_ATTRIBUTE_ERROR    equ 6
EXC_NAME_ERROR         equ 7
EXC_RUNTIME_ERROR      equ 8
EXC_STOP_ITERATION     equ 9
EXC_ZERO_DIVISION      equ 10
EXC_IMPORT_ERROR       equ 11
EXC_NOT_IMPLEMENTED    equ 12
EXC_FILE_NOT_FOUND     equ 13
EXC_OVERFLOW_ERROR     equ 14
EXC_ASSERTION_ERROR    equ 15
EXC_KEYBOARD_INTERRUPT equ 16
EXC_MEMORY_ERROR       equ 17
EXC_RECURSION_ERROR    equ 18
EXC_SYSTEM_EXIT        equ 19
EXC_OS_ERROR           equ 20
EXC_LOOKUP_ERROR       equ 21
EXC_ARITHMETIC_ERROR   equ 22
EXC_UNICODE_ERROR          equ 23
EXC_BASE_EXCEPTION_GROUP   equ 24
EXC_EXCEPTION_GROUP        equ 25
EXC_CANCELLED_ERROR        equ 26
EXC_STOP_ASYNC_ITERATION   equ 27
EXC_TIMEOUT_ERROR          equ 28

; Exception object
struc PyExceptionObject
    .ob_refcnt:     resq 1  ; +0
    .ob_type:       resq 1  ; +8
    .exc_type:      resq 1  ; +16: ptr to exception type object
    .exc_value:     resq 1  ; +24: value, as a Value
    .exc_tb:        resq 1  ; +32: ptr to traceback or NULL
    .exc_context:   resq 1  ; +40: ptr to __context__ or NULL
    .exc_cause:     resq 1  ; +48: ptr to __cause__ or NULL
    .exc_args:      resq 1  ; +56: ptr to args tuple or NULL
    .exc_dict:      resq 1  ; +64: ptr to instance dict or NULL (for custom attrs)
    .exc_suppress:  resq 1  ; +72: __suppress_context__ (set by `raise .. from`)
endstruc

; Exception group object (extends PyExceptionObject with eg_exceptions)
struc PyExceptionGroupObject
    .ob_refcnt:     resq 1  ; +0
    .ob_type:       resq 1  ; +8
    .exc_type:      resq 1  ; +16
    .exc_value:     resq 1  ; +24 (message, as a Value)
    .exc_tb:        resq 1  ; +32
    .exc_context:   resq 1  ; +40
    .exc_cause:     resq 1  ; +48
    .exc_args:      resq 1  ; +56
    .exc_dict:      resq 1  ; +64: ptr to instance dict or NULL
    .exc_suppress:  resq 1  ; +72: __suppress_context__
    .eg_exceptions: resq 1  ; +80: tuple of sub-exceptions
endstruc

; Traceback object
struc PyTracebackObject
    .ob_refcnt: resq 1  ; +0
    .ob_type:   resq 1  ; +8
    .tb_next:   resq 1  ; +16: ptr to next traceback or NULL
    .tb_lineno: resq 1  ; +24: line number (i64), 0 when unknown
    .tb_code:   resq 1  ; +32: owned ref to the PyCodeObject, or NULL
    .tb_lasti:  resq 1  ; +40: instruction offset in code units
endstruc

; Fatal error codes (non-Python, internal)

;; ============================================================================
;; Builtin function ids and PyBuiltinObject
;; (was include/builtins.inc)
;; ============================================================================

; Builtin function identifiers

; Builtin C function object
struc PyBuiltinObject
    .ob_refcnt:   resq 1  ; +0
    .ob_type:     resq 1  ; +8
    .func_id:     resq 1  ; +16: builtin function ID
    .func_name:   resq 1  ; +24: ptr to name string
    .func_ptr:    resq 1  ; +32: ptr to C implementation
    .min_args:    resq 1  ; +40: minimum nargs (including self), 0 = no check
    .max_args:    resq 1  ; +48: maximum nargs, -1 = no max check
    ; The two below are what a repr needs and nothing else reads.  CPython
    ; has three distinct types here -- builtin_function_or_method,
    ; method_descriptor and wrapper_descriptor -- reprd three ways; this tree
    ; has one, so the type it belongs to and which kind it is are fields.
    .func_owner:  resq 1  ; +56: the type whose method this is, or 0
    .func_kind:   resq 1  ; +64: 0 plain function, 1 method, 2 slot wrapper
endstruc

BUILTIN_KIND_FUNCTION equ 0
BUILTIN_KIND_METHOD   equ 1
BUILTIN_KIND_WRAPPER  equ 2
; Wrapped in a classmethod or a staticmethod, so it belongs to the TYPE
; rather than to an instance: int.from_bytes, float.fromhex, dict.fromkeys,
; str.maketrans.  CPython's METH_CLASS and METH_STATIC both repr this way --
; "<built-in method from_bytes of type object at 0x...>" -- and the receiver
; check in builtin_func_call has to leave them alone, since what arrives is a
; class or nothing at all rather than one of the owner's instances.
BUILTIN_KIND_ON_TYPE equ 3

;; ============================================================================
;; The GC header, and the traverse helpers
;; (was include/gc.inc)
;; ============================================================================

; Cycle-collecting GC, CPython 3.12 compatible

; PyGC_Head — prepended BEFORE PyObject in GC-tracked allocations
; User code gets pointer at alloc_ptr + GC_HEAD_SIZE
struc PyGC_Head
    .gc_next: resq 1       ; +0: doubly-linked list next (ptr to PyGC_Head)
    .gc_prev: resq 1       ; +8: prev ptr; low 2 bits = state flags during collection
endstruc

GC_HEAD_SIZE equ PyGC_Head_size   ; 16

; gc.set_debug() flags, with CPython's values.  DEBUG_LEAK is the union of
; the three that keep something around to look at.
GC_DEBUG_STATS         equ 1
GC_DEBUG_COLLECTABLE   equ 2
GC_DEBUG_UNCOLLECTABLE equ 4
GC_DEBUG_SAVEALL       equ 32
GC_DEBUG_LEAK          equ GC_DEBUG_COLLECTABLE | GC_DEBUG_UNCOLLECTABLE | GC_DEBUG_SAVEALL

; GC state bits stored in low 2 bits of gc_prev
GC_PREV_MASK_COLLECTING equ 1     ; object is in unreachable set
GC_PREV_MASK_FINALIZED  equ 2     ; __del__ has already run on this object
GC_PREV_SHIFT           equ 2     ; gc_refs stored in bits 2+
GC_PREV_MASK            equ ~3    ; mask to extract prev pointer (clear low 2 bits)

; VISIT_V — call visit callback on a NaN-boxed Value if it holds a pointer
; r14 must be loaded with the visit callback function pointer before use
%macro VISIT_V 2                  ; %1 = Value reg, %2 = scratch (clobbered)
    lea %2, [%1 - 1]
    cmp %2, [rel v_ptr_max_m1]
    ja %%skip                     ; immediate or NULL — not a reference
%ifnidni %1, rdi
    mov rdi, %1
%endif
    call r14                      ; visit callback(obj)
%%skip:
%endmacro

; VISIT_PTR — call visit callback on a plain heap pointer (NULL-safe)
%macro VISIT_PTR 1                ; %1 = ptr_reg
    test %1, %1
    jz %%skip
%ifnidni %1, rdi
    mov rdi, %1
%endif
    call r14
%%skip:
%endmacro

%endif ; OBJECT_INC
