; pyo/genericalias.asm - types.GenericAlias: `list[int]` as an object (PEP 585)
;
; Split out of pyo/descriptors.asm, which was at the 100k cap that
; src/compiler/lint.py holds hand-written files to -- four bytes of headroom,
; so the next line written into it failed the build.  This is the same seam
; uniontype.asm was cut along and the file's own docblock already named: an
; alias is a type of its own, reached through __class_getitem__ and nb_or,
; and it shares nothing with the descriptors around it but the tables that
; name its slots.
;
; union_type stays behind, because it is spelt in the same table block as the
; descriptor types; it borrows generic_alias_dealloc and the two are the same
; two-field record, which is why that one is exported.

%include "macros.inc"
%include "object.inc"
%include "opcodes.inc"

; --- what descriptors.asm keeps ---
extern ga_name_str
extern generic_alias_as_number
extern union_type

; --- the rest of the tree ---
extern ap_free
extern ap_malloc
extern builtin_sub_alloc
extern ap_strcmp
extern bool_false
extern bool_true
extern dict_get
extern ellipsis_singleton
extern exc_TypeError_type
extern get_iterator
extern none_type
extern obj_decref
extern obj_dealloc
extern obj_hash
extern obj_incref
extern str_from_cstr_heap
extern obj_getattr_opt
extern obj_repr
extern obj_richcompare_bool
extern raise_exception
extern str_from_cstr
extern str_new_heap
extern str_type
extern tuple_new
extern obj_call_n
extern rbt_append_cstr
extern mapping_getitem_opt
extern tuple_type
extern type_type

section .text

;; ============================================================================
;; types.GenericAlias -- what `list[int]` evaluates to (PEP 585).
;;
;; _collections_abc does `GenericAlias = type(list[int])` at import time, and
;; every stdlib module carrying annotations reaches it eventually.  It is a
;; two-field record: the origin type and the argument.  It is callable, so
;; `list[int]()` still builds a list.
;;
;; generic_alias_new(rdi = origin type, rsi = the argument) -> rax = the alias,
;;   a new reference, or 0 with the exception pending
;; ============================================================================
DEF_FUNC generic_alias_new
    mov rdx, rsi                ; the argument
    mov rsi, rdi                ; origin
    lea rdi, [rel generic_alias_type]
    call generic_alias_new_for
    leave
    ret
END_FUNC generic_alias_new

;; ============================================================================
;; generic_alias_new_for(rdi = cls, rsi = origin, rdx = the argument Value)
;;   -> rax = a new alias of class `cls`, or 0 with the exception pending
;;
;; The same record, built as a SUBCLASS.  `_CallableGenericAlias(GenericAlias)`
;; in _collections_abc calls `super().__new__(cls, origin, args)` and the
;; object that comes back has to be a _CallableGenericAlias, or its own
;; __repr__ and __getitem__ are never reached and `collections.abc.Callable`
;; reprs as a plain alias.
;;
;; A subclass's tp_basicsize is at least ours -- __slots__ = () keeps it equal,
;; a subclass without __slots__ adds a dict word -- so the tail past our three
;; fields is zeroed here rather than assumed.
;; ============================================================================
DEF_FUNC generic_alias_new_for
    push rbx
    push r12
    push r13
    push r14
    mov r13, rdi                ; cls
    mov rbx, rsi                ; origin
    mov r12, rdx                ; args
    ; builtin_sub_alloc is the allocation half every builtin constructor that
    ; honours its class uses: it reads tp_basicsize, routes a heaptype through
    ; gc_alloc (a heaptype ALWAYS carries TYPE_FLAG_HAVE_GC, and a plain
    ; ap_malloc hands the collector a pointer sixteen bytes short of what it
    ; gave out) and a static type through ap_malloc, and zeroes the tail so a
    ; subclass's __dict__ and slots start empty.
    mov rdi, r13
    call builtin_sub_alloc
    test rax, rax
    jz .gan_oom
    mov [rax + PyGenericAliasObject.ga_origin], rbx
    mov [rax + PyGenericAliasObject.ga_args], r12
    mov qword [rax + PyGenericAliasObject.ga_starred], 0
    push rax
    mov rdi, rbx
    call obj_incref
    ; ga_args is a VALUE, not a pointer: `list[0]` puts an int immediate here
    ; and obj_incref on one writes through the number.
    mov rax, r12
    INCREF_V rax, rcx
    ; A heaptype subclass is named by its instances and must be held.
    lea rcx, [rel generic_alias_type]
    cmp r13, rcx
    je .gan_done
    mov rdi, r13
    call obj_incref
.gan_done:
    pop rax
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
.gan_oom:
    xor eax, eax
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC generic_alias_new_for

;; ============================================================================
;; generic_alias_dealloc(rdi = the alias) -> nothing; the object is freed
;;
;; union_type borrows this: a union is the same two-field record, so the two
;; release the same two fields.  It is why this one is exported.
;; ============================================================================
global generic_alias_dealloc
DEF_FUNC generic_alias_dealloc, 8            ; 1 pushes, so rsp is 16-aligned
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + PyGenericAliasObject.ga_origin]
    test rdi, rdi
    jz .gad_args
    call obj_decref
.gad_args:
    mov rax, [rbx + PyGenericAliasObject.ga_args]
    test rax, rax
    jz .gad_free
    DECREF_V rax, rcx
.gad_free:
    mov rdi, rbx
    call ap_free
    pop rbx
    leave
    ret
END_FUNC generic_alias_dealloc

;; ============================================================================
;; generic_alias_construct(rdi = type, rsi = args, rdx = nargs)
;;   -> rax = a new GenericAlias, rdx = TAG_PTR
;;
;; tp_new for generic_alias_type: types.GenericAlias(origin, args).
;;
;; The type had no constructor, so `GenericAlias(list, str)` fell through to
;; the ordinary class-construction path: it allocated a GC-headed block, left
;; ga_origin and ga_args holding whatever was there, and then freed it with
;; this type's tp_dealloc -- a plain free at the object address rather than at
;; the GC head, which glibc reports as a double free.  os.PathLike is written
;; `__class_getitem__ = classmethod(GenericAlias)`, so `os.PathLike[str]` was
;; the crash; importlib.resources is one line of it.
;; ============================================================================
;; ============================================================================
;; generic_alias_iter(rdi = the alias) -> rax = an iterator over one item, the
;;   same alias with its star set
;;
;; PEP 646 compiles `*tuple[int, str]` in an annotation as the expression
;; followed by UNPACK_SEQUENCE 1, so the value that reaches __annotations__ is
;; whatever iterating the alias yields once.  CPython's is the alias again
;; with __unpacked__ True; without a tp_iter at all the unpack said
;; "'types.GenericAlias' object is not iterable".
;;
;; A one-item tuple and its own iterator, rather than a new iterator type:
;; there is exactly one item and it is built here.
;; ============================================================================
GAI_TUP   equ 8
GAI_FRAME equ 16            ; + 0 pushes = 16-aligned
DEF_FUNC generic_alias_iter, GAI_FRAME
    mov rsi, [rdi + PyGenericAliasObject.ga_args]
    mov rdi, [rdi + PyGenericAliasObject.ga_origin]
    call generic_alias_new
    test rax, rax
    jz .gai_fail
    mov qword [rax + PyGenericAliasObject.ga_starred], 1
    mov [rbp - GAI_TUP], rax
    mov edi, 1
    extern tuple_new
    call tuple_new
    test rax, rax
    jz .gai_fail
    mov rcx, [rax + PyTupleObject.ob_item]
    mov rdx, [rbp - GAI_TUP]
    mov [rcx], rdx              ; the tuple takes the reference
    mov [rbp - GAI_TUP], rax
    mov rdi, rax
    mov esi, TAG_PTR
    extern get_iterator
    call get_iterator
    push rax
    mov rdi, [rbp - GAI_TUP]
    call obj_decref             ; the iterator holds it now
    pop rax
    leave
    ret
.gai_fail:
    xor eax, eax
    leave
    ret
END_FUNC generic_alias_iter

;; ============================================================================
;; generic_alias_construct(rdi = type, rsi = args, rdx = nargs) -> Value
;;
;; tp_new: `types.GenericAlias(list, int)` spelt out, which is what
;; _collections_abc and typing both do rather than subscripting.
;; ============================================================================
DEF_FUNC generic_alias_construct
    cmp rdx, 2
    jne .gac_error
    ; rdi is the class to build, and it is not always ours: a subclass
    ; reaching super().__new__(cls, ...) has to get an instance of ITSELF, or
    ; its own __repr__ and __getitem__ are never found.
    mov rcx, [rsi + 8]          ; the argument, whatever it is
    mov rsi, [rsi]              ; the origin
    V_TEST_PTR rsi, rax
    ja .gac_error
    test rsi, rsi
    jz .gac_error
    mov rdx, rcx
    call generic_alias_new_for
    test rax, rax
    jz .gac_failed
    mov edx, TAG_PTR            ; a constructor returns the (payload, tag) pair
    leave
    ret
.gac_failed:
    xor edx, edx
    leave
    ret
.gac_error:
    RAISE exc_TypeError_type, "GenericAlias expected 2 arguments"
END_FUNC generic_alias_construct

;; ============================================================================
;; generic_alias_dunder_new(args, nargs) -> Value    -- types.GenericAlias.__new__
;;
;; The constructor lives in tp_new and the type had no tp_dict at all, so
;; `super().__new__(cls, ...)` in a subclass walked past it to object.__new__
;; and was refused.  `_CallableGenericAlias` in _collections_abc is written
;; exactly that way, which made `collections.abc.Callable[[int], int]` a
;; TypeError outright.
;; ============================================================================
extern new_from_slot
DEF_FUNC generic_alias_dunder_new
    mov rdx, rsi
    mov rsi, rdi
    lea rdi, [rel generic_alias_type]
    call new_from_slot
    leave
    ret
END_FUNC generic_alias_dunder_new

;; ============================================================================
;; generic_alias_class_getitem(rdi = args, rsi = nargs) -> Value: the alias
;;
;; The builtin registered as __class_getitem__ on each container type.
;; args[0] = cls, args[1] = the subscript.
;; ============================================================================
DEF_FUNC generic_alias_class_getitem
    cmp rsi, 2
    jl .gacg_bad
    mov rax, [rdi + 8]
    mov rdi, [rdi]
    mov rsi, rax
    call generic_alias_new
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
.gacg_bad:
    RAISE exc_TypeError_type, "__class_getitem__() takes exactly one argument"
END_FUNC generic_alias_class_getitem

;; ============================================================================
;; generic_alias_dunder_or(args = (self, other), nargs) -> a UnionType, or
;;   NotImplemented
;;
;; `list[int] | None` was answered by the nb_or slot alone, and a slot is not
;; inherited by a Python subclass the way a dict entry is -- so
;; collections.abc's _CallableGenericAlias, a GenericAlias subclass, could not
;; be or'ed: `Callable[[Any], None] | None` in pluggy, which pytest imports
;; first thing, was a TypeError.  Published by name, they are inherited.
;; ============================================================================
global generic_alias_dunder_or
DEF_FUNC generic_alias_dunder_or
    cmp rsi, 2
    jne .gado_bad
    mov rsi, [rdi + 8]
    mov rdi, [rdi]
    leave
    jmp gad_or_common
.gado_bad:
    RAISE exc_TypeError_type, "__or__() takes exactly one argument"
END_FUNC generic_alias_dunder_or

;; ============================================================================
;; generic_alias_dunder_ror(args = (self, other), nargs) -> other | self
;; ============================================================================
global generic_alias_dunder_ror
DEF_FUNC generic_alias_dunder_ror
    cmp rsi, 2
    jne .gadr_bad
    mov rax, [rdi]
    mov rdi, [rdi + 8]
    mov rsi, rax
    leave
    jmp gad_or_common
.gadr_bad:
    RAISE exc_TypeError_type, "__ror__() takes exactly one argument"
END_FUNC generic_alias_dunder_ror

;; ============================================================================
;; gad_or_common(rdi = left, rsi = right) -> a UnionType, or NotImplemented
;;
;; Tail-jumped into from the two above with their frames already gone.
;; ============================================================================
DEF_FUNC_LOCAL gad_or_common
    extern union_type_or
    call union_type_or
    test rax, rax
    jz .goc_ni
    V_PACK rax, rdx
    leave
    ret
.goc_ni:
    extern notimpl_singleton
    lea rax, [rel notimpl_singleton]
    INCREF rax
    leave
    ret
END_FUNC gad_or_common

;; ============================================================================
;; generic_alias_mro_entries(args = (self, bases), nargs) -> (origin,)
;;
;; PEP 560: `class C(list[int])` subclasses list.  __build_class__ asks each
;; base that is not a class what to put in its place, and an alias answers
;; with its origin -- so `class D(dict["k", int])`, which setuptools'
;; pkg_resources declares at module scope, was "bases must be types".
;; ============================================================================
global generic_alias_mro_entries
DEF_FUNC generic_alias_mro_entries
    cmp rsi, 2
    jne .game_bad
    mov rax, [rdi]
    push qword [rax + PyGenericAliasObject.ga_origin]
    sub rsp, 8
    mov edi, 1
    call tuple_new
    add rsp, 8
    pop rdi
    INCREF rdi
    mov rcx, [rax + PyTupleObject.ob_item]
    mov [rcx], rdi
    leave
    ret
.game_bad:
    RAISE exc_TypeError_type, "__mro_entries__() takes exactly one argument"
END_FUNC generic_alias_mro_entries

;; ============================================================================
;; generic_alias_repr(rdi = the alias) -> rax = a PyStrObject*, or 0
;;
;; "list[int]" -- origin name, then the argument's repr.
;; ============================================================================
GAR_BUF   equ 264
GAR_SELF  equ 272
GAR_FRAME equ 296            ; + 5 pushes = 336, 16-aligned
DEF_FUNC generic_alias_repr, GAR_FRAME
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov [rbp - GAR_SELF], rdi
    lea rbx, [rbp - GAR_BUF]
    xor r13d, r13d

    ; An UNPACKED alias reprs with a leading star: `*tuple[int, str]` is what
    ; PEP 646 writes and what CPython prints back.
    cmp qword [rdi + PyGenericAliasObject.ga_starred], 0
    je .gar_no_star
    mov byte [rbx], '*'
    mov r13d, 1
.gar_no_star:

    mov rax, [rdi + PyGenericAliasObject.ga_origin]
    test rax, rax
    jz .gar_open
    mov rsi, [rax + PyObject.ob_type]
    test rsi, rsi
    jz .gar_open
    test qword [rsi + PyTypeObject.tp_flags], TYPE_FLAG_METATYPE
    jz .gar_open
    mov rdi, rax
    call .gar_qualified

.gar_open:
    mov byte [rbx + r13], '['
    inc r13
    mov rdi, [rbp - GAR_SELF]
    mov rdi, [rdi + PyGenericAliasObject.ga_args]
    test rdi, rdi
    jz .gar_close
    ; A tuple argument prints comma-joined without its parentheses, and a
    ; type prints as its name: list[int], not list[<class 'int'>].
    extern tuple_type
    V_TEST_PTR rdi, rax         ; classify before reading ob_type: the
    ja .gar_one                 ; argument may be a number
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel tuple_type]
    cmp rax, rcx
    jne .gar_one
    mov r14, [rdi + PyTupleObject.ob_size]
    mov r15, [rdi + PyTupleObject.ob_item]
    xor r12d, r12d
.gar_tuple_loop:
    cmp r12, r14
    jge .gar_close
    test r12, r12
    jz .gar_no_comma
    mov byte [rbx + r13], ','
    mov byte [rbx + r13 + 1], ' '
    add r13, 2
.gar_no_comma:
    mov rdi, [r15 + r12*8]
    call .gar_emit_one
    inc r12
    jmp .gar_tuple_loop

.gar_one:
    call .gar_emit_one
    jmp .gar_close

;; .gar_emit_one(rdi = a Value) -- append its display form to the buffer
.gar_emit_one:
    push r12
    push r14
    push r15
    ; ... shows as "...", which is what CPython's alias repr does even though
    ; repr(Ellipsis) is "Ellipsis"
    extern ellipsis_singleton
    lea rax, [rel ellipsis_singleton]
    cmp rdi, rax
    jne .geo_not_ellipsis
    cmp r13, GAR_BUF - 8
    jae .geo_done
    mov byte [rbx + r13], '.'
    mov byte [rbx + r13 + 1], '.'
    mov byte [rbx + r13 + 2], '.'
    add r13, 3
    jmp .geo_done
.geo_not_ellipsis:
    ; a type shows as its (unqualified) name
    V_TEST_PTR rdi, rax
    ja .geo_repr
    test rdi, rdi
    jz .geo_repr
    mov rax, [rdi + PyObject.ob_type]
    test rax, rax
    jz .geo_repr
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_METATYPE
    jz .geo_repr
    call .gar_qualified
    jmp .geo_done

.geo_repr:
    call obj_repr
    V_UNPACK rax, rdx
    test rax, rax
    jz .geo_done
    push rax
    mov r8, [rax + PyStrObject.ob_size]
    lea rsi, [rax + PyStrObject.data]
    xor ecx, ecx
.geo_repr_copy:
    cmp rcx, r8
    jge .geo_repr_done
    cmp r13, GAR_BUF - 8
    jae .geo_repr_done
    movzx eax, byte [rsi + rcx]
    mov [rbx + r13], al
    inc r13
    inc rcx
    jmp .geo_repr_copy
.geo_repr_done:
    pop rdi
    call obj_decref
.geo_done:
    pop r15
    pop r14
    pop r12
    ret


;; .gar_qualified(rdi = a class) -- append "module.QualName" to rbx at r13.
;;
;; CPython writes an alias's origin and its type arguments the way it writes a
;; class in an annotation: qualified by module, with "builtins" left off, and
;; using __qualname__ so a nested class keeps its "Outer.Inner".  Only the
;; bare tp_name was written, which for a class built by a metaclass of its own
;; -- every ABC, and os.PathLike is one -- was not reached at all, because the
;; test for "is this a class?" was a comparison against the two metatypes this
;; tree ships rather than TYPE_FLAG_METATYPE.
.gar_qualified:
    push r12
    push r14
    push r15
    mov r12, rdi                    ; the class
    mov r14, [rdi + PyTypeObject.tp_dict]

    ; --- the module, unless it is "builtins" ---
    test r14, r14
    jz .gq_module_from_name
    CSTRING rdi, "__module__"
    call str_from_cstr
    mov rsi, rax
    mov rdi, r14
    call dict_get
    V_UNPACK rax, rdx
    test edx, edx
    jz .gq_module_from_name
    cmp edx, TAG_PTR
    jne .gq_module_from_name
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    jne .gq_module_from_name
    lea rsi, [rax + PyStrObject.data]
    mov rdi, rsi
    CSTRING rsi, "builtins"
    push rdi
    call ap_strcmp
    pop rsi
    test eax, eax
    jz .gq_qualname                 ; "builtins" is left off
    call .gq_copy_cstr
    mov byte [rbx + r13], '.'
    inc r13
    jmp .gq_qualname

.gq_module_from_name:
    ; A static type records no __module__; its tp_name carries the dotted
    ; prefix instead -- "types.GenericAlias" -- and everything else is a
    ; builtin, which prints unqualified either way.
    mov rsi, [r12 + PyTypeObject.tp_name]
    xor ecx, ecx
    xor r15, r15                    ; length of the prefix, 0 for none
.gq_scan:
    movzx eax, byte [rsi + rcx]
    test al, al
    jz .gq_scanned
    cmp al, '.'
    jne .gq_scan_next
    lea r15, [rcx + 1]
.gq_scan_next:
    inc rcx
    jmp .gq_scan
.gq_scanned:
    test r15, r15
    jz .gq_qualname
    xor ecx, ecx
.gq_prefix:
    cmp rcx, r15
    jge .gq_qualname
    cmp r13, GAR_BUF - 8
    jae .gq_qualname
    movzx eax, byte [rsi + rcx]
    mov [rbx + r13], al
    inc r13
    inc rcx
    jmp .gq_prefix

.gq_qualname:
    test r14, r14
    jz .gq_from_tp_name
    CSTRING rdi, "__qualname__"
    call str_from_cstr
    mov rsi, rax
    mov rdi, r14
    call dict_get
    V_UNPACK rax, rdx
    test edx, edx
    jz .gq_from_tp_name
    cmp edx, TAG_PTR
    jne .gq_from_tp_name
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    jne .gq_from_tp_name
    lea rsi, [rax + PyStrObject.data]
    call .gq_copy_cstr
    jmp .gq_done

.gq_from_tp_name:
    ; The last dotted component: "types.GenericAlias" prints "GenericAlias",
    ; the prefix having gone in as the module above.
    mov rsi, [r12 + PyTypeObject.tp_name]
    mov rdi, rsi
    xor ecx, ecx
.gq_last_dot:
    movzx eax, byte [rsi + rcx]
    test al, al
    jz .gq_tail
    cmp al, '.'
    jne .gq_dot_next
    lea rdi, [rsi + rcx + 1]
.gq_dot_next:
    inc rcx
    jmp .gq_last_dot
.gq_tail:
    mov rsi, rdi
    call .gq_copy_cstr
.gq_done:
    pop r15
    pop r14
    pop r12
    ret

;; .gq_copy_cstr(rsi = a NUL-terminated string) -- append it, bounded.
.gq_copy_cstr:
    movzx eax, byte [rsi]
    test al, al
    jz .gq_copied
    inc rsi
    cmp r13, GAR_BUF - 8
    jae .gq_copied
    mov [rbx + r13], al
    inc r13
    jmp .gq_copy_cstr
.gq_copied:
    ret

.gar_close:
    mov byte [rbx + r13], ']'
    inc r13
    mov rdi, rbx
    mov rsi, r13
    call str_new_heap
    mov edx, TAG_PTR
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC generic_alias_repr

;; ============================================================================
;; generic_alias_call(rdi = the alias, rsi = args, rdx = nargs) -> Value
;;
;; Calling an alias constructs the origin: list[int]() is a list.  Tail-jumps
;; into the origin's own tp_call, so the alias costs nothing at the call.
;; ============================================================================
DEF_FUNC_BARE generic_alias_call
    mov rax, [rdi + PyGenericAliasObject.ga_origin]
    mov rdi, rax
    mov rcx, [rax + PyObject.ob_type]
    mov rcx, [rcx + PyTypeObject.tp_call]
    test rcx, rcx
    jz .gac_bad
    jmp rcx
.gac_bad:
    RAISE exc_TypeError_type, "generic alias is not callable"
END_FUNC generic_alias_call

;; ============================================================================
;; generic_alias_getattr(rdi = the alias, rsi = name str) -> Value, or 0
;;
;; __origin__ and __args__, the two fields typing reads off an alias.
;; ============================================================================
GAG_NAME  equ 8
GAG_FRAME equ 24            ; + 1 push = 32, 16-aligned

DEF_FUNC generic_alias_getattr, GAG_FRAME
    push rbx
    mov rbx, rdi
    mov [rbp - GAG_NAME], rsi
    lea rdi, [rsi + PyStrObject.data]
    CSTRING rsi, "__origin__"
    call ap_strcmp
    test eax, eax
    jz .gag_origin

    ; __args__ is always a tuple, even when the subscript was one thing:
    ; CPython wraps it, and typing.get_args() and every annotation reader
    ; expect that.  This used to answer NULL, which reads as "no attribute".
    mov rdi, [rbp - GAG_NAME]
    lea rdi, [rdi + PyStrObject.data]
    CSTRING rsi, "__args__"
    call ap_strcmp
    test eax, eax
    jz .gag_args

    ; typing walks __parameters__ to find the TypeVars an alias is still
    ; generic over.  It is the TypeVars among the arguments, in first-seen
    ; order, and it answered nothing at all -- so list[T].__parameters__ was
    ; an AttributeError where CPython says (~T,).
    mov rdi, [rbp - GAG_NAME]
    lea rdi, [rdi + PyStrObject.data]
    CSTRING rsi, "__parameters__"
    call ap_strcmp
    test eax, eax
    jz .gag_parameters

    ; PEP 646 asks whether an alias is the unpacked form, and typing reads it
    ; by name.
    mov rdi, [rbp - GAG_NAME]
    lea rdi, [rdi + PyStrObject.data]
    CSTRING rsi, "__unpacked__"
    call ap_strcmp
    test eax, eax
    jnz .gag_missing
    cmp qword [rbx + PyGenericAliasObject.ga_starred], 0
    je .gag_not_unpacked
    lea rax, [rel bool_true]
    jmp .gag_bool
.gag_not_unpacked:
    lea rax, [rel bool_false]
.gag_bool:
    INCREF rax
    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.gag_parameters:
    ; Built each time rather than cached: CPython caches it on the object and
    ; the field would have to be traversed by the collector, and nothing here
    ; asks for it in a loop.  A TypeVar is anything with a __typing_subst__,
    ; which is how typing itself recognises one.
    mov rdi, rbx
    call generic_alias_parameters
    test rax, rax
    jz .gag_missing
    mov edx, TAG_PTR
    pop rbx
    leave
    V_PACK rax, rdx
    ret

.gag_args:

    mov rax, [rbx + PyGenericAliasObject.ga_args]
    test rax, rax
    jz .gag_empty_args
    V_TEST_PTR rax, rcx
    ja .gag_wrap_args
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel tuple_type]
    cmp rcx, rdx
    jne .gag_wrap_args
    mov rdi, rax
    call obj_incref
    mov rax, [rbx + PyGenericAliasObject.ga_args]
    mov edx, TAG_PTR
    pop rbx
    leave
    ret
.gag_wrap_args:
    mov edi, 1
    call tuple_new
    test rax, rax
    jz .gag_missing
    mov rcx, [rbx + PyGenericAliasObject.ga_args]
    mov rdx, [rax + PyTupleObject.ob_item]
    mov [rdx], rcx
    push rax
    mov rax, rcx
    INCREF_V rax, rcx
    pop rax
    mov edx, TAG_PTR
    pop rbx
    leave
    ret
.gag_empty_args:
    xor edi, edi
    call tuple_new
    mov edx, TAG_PTR
    pop rbx
    leave
    ret

.gag_missing:
    xor eax, eax
    xor edx, edx
    pop rbx
    leave
    ret
.gag_origin:
    mov rax, [rbx + PyGenericAliasObject.ga_origin]
    push rax
    mov rdi, rax
    call obj_incref
    pop rax
    mov edx, TAG_PTR
    pop rbx
    leave
    ret
END_FUNC generic_alias_getattr

;; ============================================================================
;; generic_alias_parameters(rdi = a generic alias) -> rax = a tuple, owned,
;;   or 0
;;
;; The TypeVars among the alias's arguments, in first-seen order and without
;; repeats -- which is what typing walks to find what an alias is still
;; generic over.  `list[T].__parameters__` was an AttributeError; CPython
;; answers (~T,).
;;
;; A TypeVar is recognised the way typing itself recognises one: by having a
;; __typing_subst__.  That keeps this from naming lib/_typing.py's classes,
;; so a TypeVar from a real typing module counts too.
;; ============================================================================
GAP_SELF  equ 8
GAP_OUT   equ 16
GAP_N     equ 24
GAP_FRAME equ 32            ; + 2 pushes = 48, 16-aligned
DEF_FUNC_LOCAL generic_alias_parameters, GAP_FRAME
    push rbx
    push r12
    mov [rbp - GAP_SELF], rdi
    mov qword [rbp - GAP_N], 0

    ; The arguments, always as a tuple: ga_args holds the bare object when the
    ; subscript was one thing.
    mov rbx, [rdi + PyGenericAliasObject.ga_args]
    test rbx, rbx
    jz .gap_empty
    V_TEST_PTR rbx, rcx
    ja .gap_single
    lea rcx, [rel tuple_type]
    cmp [rbx + PyObject.ob_type], rcx
    jne .gap_single
    mov r12, [rbx + PyTupleObject.ob_size]
    jmp .gap_have_n
.gap_single:
    mov r12d, 1
.gap_have_n:

    ; One pass to count, one to fill: a tuple cannot grow.  The counting pass
    ; runs with no output tuple, and gap_already then has nothing to dedup
    ; against -- so it walks the arguments it has already passed instead.
    ; That cannot see a TypeVar contributed by a NESTED alias, so the count
    ; may come out high; the fill pass dedups properly and the tuple is
    ; trimmed to what it actually wrote.
    xor eax, eax
    mov [rbp - GAP_OUT], rax
    call gap_collect             ; counts into GAP_N
    mov rdi, [rbp - GAP_N]
    call tuple_new
    test rax, rax
    jz .gap_fail
    mov [rbp - GAP_OUT], rax
    mov qword [rbp - GAP_N], 0
    call gap_collect             ; fills GAP_OUT
    ; Trim: the counting pass could not dedup across nested aliases, so the
    ; tuple may be longer than what was written.  The tail is NULL, and a
    ; tuple with a NULL in it is not a tuple anyone may see.
    mov rax, [rbp - GAP_OUT]
    mov rcx, [rbp - GAP_N]
    cmp rcx, [rax + PyTupleObject.ob_size]
    je .gap_exact
    mov rdi, rcx
    call tuple_new
    test rax, rax
    jz .gap_fail_out
    mov rdx, [rbp - GAP_OUT]
    mov rdx, [rdx + PyTupleObject.ob_item]
    mov r8, [rax + PyTupleObject.ob_item]
    xor ecx, ecx
.gap_trim:
    cmp rcx, [rbp - GAP_N]
    jge .gap_trimmed
    mov r9, [rdx + rcx*8]
    mov [r8 + rcx*8], r9
    mov rdi, r9
    push rax
    push rcx
    call obj_incref
    pop rcx
    pop rax
    inc rcx
    jmp .gap_trim
.gap_trimmed:
    push rax
    mov rdi, [rbp - GAP_OUT]
    call obj_decref
    pop rax
    pop r12
    pop rbx
    leave
    ret
.gap_exact:
    mov rax, [rbp - GAP_OUT]
    pop r12
    pop rbx
    leave
    ret
.gap_fail_out:
    mov rdi, [rbp - GAP_OUT]
    call obj_decref
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret

.gap_empty:
    xor edi, edi
    call tuple_new
    pop r12
    pop rbx
    leave
    ret
.gap_fail:
    xor eax, eax
    pop r12
    pop rbx
    leave
    ret
END_FUNC generic_alias_parameters

;; ============================================================================
;; generic_alias_subscript(rdi = the alias, rsi = the key Value) -> Value
;;
;; mp_subscript: PEP 585's parameter substitution, `list[T][int]` -> `list[int]`.
;;
;; The type carried no tp_as_mapping at all, so an alias that was still
;; generic could not be filled in: `list[T][int]` said "'types.GenericAlias'
;; object is not subscriptable", and so did every `C[T][int]` for a
;; Generic subclass, since typing builds those on this.  It was the largest
;; single cause of failure in CPython's own test_typing.
;;
;; CPython's _Py_subs_parameters, with its three arms per argument: a TypeVar
;; is substituted through its own __typing_subst__, a nested alias that is
;; still generic is subscripted with the items ITS parameters ask for, and
;; anything else is carried over.
;; ============================================================================
GAS_SELF   equ 8
GAS_KEY    equ 16
GAS_PARAMS equ 24           ; __parameters__, owned
GAS_ITEMS  equ 32           ; the key as a tuple, owned
GAS_ARGS   equ 40           ; self's arguments as a tuple, owned
GAS_NEW    equ 48           ; the tuple being built, owned
GAS_I      equ 56
GAS_FRAME  equ 64           ; + 2 pushes = 80, 16-aligned

DEF_FUNC generic_alias_subscript, GAS_FRAME
    push rbx
    push r12
    mov [rbp - GAS_SELF], rdi
    mov [rbp - GAS_KEY], rsi
    xor eax, eax
    mov [rbp - GAS_PARAMS], rax
    mov [rbp - GAS_ITEMS], rax
    mov [rbp - GAS_ARGS], rax
    mov [rbp - GAS_NEW], rax

    call generic_alias_parameters
    test rax, rax
    jz .gas_fail
    mov [rbp - GAS_PARAMS], rax
    cmp qword [rax + PyTupleObject.ob_size], 0
    je .gas_no_params

    ; The key as a tuple.  `a[int]` and `a[int, str]` differ only in whether
    ; the subscript already arrived as one.
    mov rbx, [rbp - GAS_KEY]
    call gas_as_tuple
    test rax, rax
    jz .gas_fail
    mov [rbp - GAS_ITEMS], rax

    mov rcx, [rbp - GAS_PARAMS]
    mov rcx, [rcx + PyTupleObject.ob_size]
    cmp [rax + PyTupleObject.ob_size], rcx
    jl .gas_too_few
    jg .gas_too_many

    ; Our own arguments, as a tuple, the way __args__ reports them.
    mov rdi, [rbp - GAS_SELF]
    mov rbx, [rdi + PyGenericAliasObject.ga_args]
    call gas_as_tuple
    test rax, rax
    jz .gas_fail
    mov [rbp - GAS_ARGS], rax

    mov rdi, [rax + PyTupleObject.ob_size]
    call tuple_new
    test rax, rax
    jz .gas_fail
    mov [rbp - GAS_NEW], rax

    mov qword [rbp - GAS_I], 0
.gas_loop:
    mov rax, [rbp - GAS_ARGS]
    mov rcx, [rbp - GAS_I]
    cmp rcx, [rax + PyTupleObject.ob_size]
    jge .gas_built
    mov rax, [rax + PyTupleObject.ob_item]
    mov rbx, [rax + rcx*8]              ; the argument, a Value

    ; Arm one: a TypeVar, recognised as typing recognises one.
    V_TEST_PTR rbx, rcx
    ja .gas_keep
    mov rdi, rbx
    CSTRING rsi, "__typing_subst__"
    call gap_has_attr
    test eax, eax
    jnz .gas_typevar

    ; Arm two: something still generic of its own -- a nested alias.
    mov rdi, rbx
    CSTRING rsi, "__parameters__"
    call gap_has_attr
    test eax, eax
    jnz .gas_nested

.gas_keep:
    mov rax, [rbp - GAS_NEW]
    mov rcx, [rbp - GAS_I]
    mov rax, [rax + PyTupleObject.ob_item]
    mov [rax + rcx*8], rbx
    mov rax, rbx
    INCREF_V rax, rcx
    jmp .gas_next

.gas_typevar:
    ; items[params.index(arg)], handed to arg.__typing_subst__
    mov rdi, rbx
    mov rsi, [rbp - GAS_PARAMS]
    mov rdx, [rbp - GAS_ITEMS]
    call gas_item_for
    test rax, rax
    jz .gas_fail
    mov r12, rax                        ; the item, borrowed from GAS_ITEMS
    mov rdi, rbx
    CSTRING rsi, "__typing_subst__"
    mov rdx, r12
    call gas_call_1
    test rax, rax
    jz .gas_fail
    mov rcx, [rbp - GAS_NEW]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov rdx, [rbp - GAS_I]
    mov [rcx + rdx*8], rax              ; the call's reference goes in
    jmp .gas_next

.gas_nested:
    mov rdi, rbx
    mov rsi, [rbp - GAS_PARAMS]
    mov rdx, [rbp - GAS_ITEMS]
    call gas_subst_nested
    test rax, rax
    jz .gas_fail
    mov rcx, [rbp - GAS_NEW]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov rdx, [rbp - GAS_I]
    mov [rcx + rdx*8], rax
    jmp .gas_next

.gas_next:
    inc qword [rbp - GAS_I]
    jmp .gas_loop

.gas_built:
    ; ga_args holds the bare object when the subscript was one thing, and a
    ; tuple otherwise -- `list[int]` stores int, `tuple[int, str]` stores the
    ; pair.  Handing back a one-tuple here instead would make
    ; `list[T][int] == list[int]` False, since richcompare compares the field
    ; rather than what __args__ wraps it into.
    mov rsi, [rbp - GAS_NEW]
    cmp qword [rsi + PyTupleObject.ob_size], 1
    jne .gas_emit
    mov rax, [rsi + PyTupleObject.ob_item]
    mov rsi, [rax]
.gas_emit:
    mov rdi, [rbp - GAS_SELF]
    mov rdi, [rdi + PyGenericAliasObject.ga_origin]
    call generic_alias_new
    test rax, rax
    jz .gas_fail
    push rax
    call gas_release
    pop rax
    mov edx, TAG_PTR
    pop r12
    pop rbx
    leave
    ret

.gas_fail:
    call gas_release
    xor eax, eax
    xor edx, edx
    pop r12
    pop rbx
    leave
    ret

.gas_no_params:
    mov rdi, [rbp - GAS_SELF]
    CSTRING rsi, " is not a generic class"
    jmp .gas_raise
.gas_too_few:
    mov rdi, [rbp - GAS_SELF]
    CSTRING rsi, ": too few arguments"
    jmp .gas_raise
.gas_too_many:
    mov rdi, [rbp - GAS_SELF]
    CSTRING rsi, ": too many arguments"
.gas_raise:
    push rdi
    push rsi
    call gas_release
    pop rsi
    pop rdi
    call gas_raise_named            ; does not return
END_FUNC generic_alias_subscript

;; ============================================================================
;; gas_raise_named(rdi = the alias, rsi = the rest of the sentence, a cstr)
;;   -> does not return: a TypeError naming the alias
;;
;; CPython words all three refusals around the alias's own repr -- "list[int]
;; is not a generic class" -- and test_typing matches that phrase, so the
;; repr has to be in the message rather than a generic stand-in for it.
;; ============================================================================
GRN_SUFFIX equ 8
GRN_REPR   equ 16
GRN_BUF    equ 208
GRN_FRAME  equ 208          ; + 0 pushes = 208, 16-aligned
DEF_FUNC_LOCAL gas_raise_named, GRN_FRAME
    mov [rbp - GRN_SUFFIX], rsi
    call obj_repr
    mov [rbp - GRN_REPR], rax
    lea rdi, [rbp - GRN_BUF]
    test rax, rax
    jz .grn_noname
    lea rsi, [rax + PyStrObject.data]
    call rbt_append_cstr
    jmp .grn_suffix
.grn_noname:
    CSTRING rsi, "the alias"
    call rbt_append_cstr
.grn_suffix:
    mov rdi, rax
    mov rsi, [rbp - GRN_SUFFIX]
    call rbt_append_cstr
    mov rdi, [rbp - GRN_REPR]
    test rdi, rdi
    jz .grn_go
    call obj_decref
.grn_go:
    lea rdi, [rel exc_TypeError_type]
    lea rsi, [rbp - GRN_BUF]
    call raise_exception
END_FUNC gas_raise_named

;; ============================================================================
;; gas_release() -- drop the four owned temporaries in the caller's frame
;;
;; Only callable from generic_alias_subscript's frame.  -> nothing
;; ============================================================================
DEF_FUNC_BARE gas_release
    push rbx
    push r12
    sub rsp, 8                  ; entered by CALL, so rsp arrives 8 mod 16 and
                                ; an EVEN push list leaves obj_decref below
                                ; misaligned; the pad is what squares it
    mov ebx, GAS_PARAMS
.gasr_loop:
    mov rax, rbp
    sub rax, rbx
    mov rdi, [rax]
    test rdi, rdi
    jz .gasr_next
    mov qword [rax], 0
    mov r12, rbx
    call obj_decref
    mov rbx, r12
.gasr_next:
    add rbx, 8
    cmp rbx, GAS_NEW
    jle .gasr_loop
    add rsp, 8
    pop r12
    pop rbx
    ret
END_FUNC gas_release

;; ============================================================================
;; gas_as_tuple(rbx = a Value) -> rax = a tuple, OWNED, or 0
;;
;; The subscript and the argument list are both "a tuple, or the one thing
;; that would have been in it".  A tuple is handed back with a reference
;; taken, anything else is wrapped in a one-tuple, so the caller releases
;; exactly one thing either way.
;; ============================================================================
DEF_FUNC_BARE gas_as_tuple
    push rbx
    test rbx, rbx
    jz .gast_wrap
    V_TEST_PTR rbx, rcx
    ja .gast_wrap
    lea rcx, [rel tuple_type]
    cmp [rbx + PyObject.ob_type], rcx
    jne .gast_wrap
    mov rdi, rbx
    call obj_incref
    mov rax, rbx
    pop rbx
    ret
.gast_wrap:
    mov edi, 1
    call tuple_new
    test rax, rax
    jz .gast_out
    mov rcx, [rax + PyTupleObject.ob_item]
    mov [rcx], rbx
    push rax
    mov rax, rbx
    INCREF_V rax, rcx
    pop rax
.gast_out:
    pop rbx
    ret
END_FUNC gas_as_tuple

;; ============================================================================
;; gas_item_for(rdi = a TypeVar, rsi = the __parameters__ tuple,
;;              rdx = the items tuple) -> rax = the item chosen for it,
;;   BORROWED from the items tuple, or 0 when the TypeVar is not among them
;;
;; The position of the TypeVar in __parameters__ chooses the item.  The two
;; tuples are ARGUMENTS rather than frame slots because a nested alias reaches
;; this through a function of its own: reading the caller's rbp worked only
;; for the direct call, and `list[list[T]][int]` failed with nothing pending.
;; ============================================================================
DEF_FUNC_BARE gas_item_for
    push rbx
    push r12
    mov r12, rdi
    mov rcx, [rsi + PyTupleObject.ob_size]
    mov rax, [rsi + PyTupleObject.ob_item]
    xor ebx, ebx
.gasi_loop:
    cmp rbx, rcx
    jge .gasi_missing
    cmp [rax + rbx*8], r12
    je .gasi_found
    inc rbx
    jmp .gasi_loop
.gasi_found:
    mov rax, [rdx + PyTupleObject.ob_item]
    mov rax, [rax + rbx*8]
    pop r12
    pop rbx
    ret
.gasi_missing:
    xor eax, eax
    pop r12
    pop rbx
    ret
END_FUNC gas_item_for

;; ============================================================================
;; gas_call_1(rdi = an object, rsi = a method name cstr, rdx = one argument
;;   Value) -> rax = the result Value, or 0 with the exception pending
;; ============================================================================
GC1_ARG   equ 8
GC1_FN    equ 16
; Three values used to be carried across calls on the machine stack, one push
; each -- and a single push makes the call after it misaligned, because
; DEF_FUNC's frame already leaves rsp where the ABI wants it.  Frame slots
; instead: they cost the same and they cannot be odd.
GC1_OBJ   equ 24
GC1_TMP   equ 32
GC1_FRAME equ 48            ; + 0 pushes = 48, 16-aligned
DEF_FUNC_LOCAL gas_call_1, GC1_FRAME
    mov [rbp - GC1_ARG], rdx
    mov [rbp - GC1_OBJ], rdi
    mov rdi, rsi
    call str_from_cstr_heap
    mov [rbp - GC1_FN], rax
    mov rdi, [rbp - GC1_OBJ]
    test rax, rax
    jz .gc1_fail
    mov rsi, rax
    call obj_getattr_opt
    mov [rbp - GC1_TMP], rax
    mov rdi, [rbp - GC1_FN]
    call obj_decref
    mov rdi, [rbp - GC1_TMP]
    test rdi, rdi
    jz .gc1_fail
    mov [rbp - GC1_FN], rdi             ; the bound method, ours to release
    lea rsi, [rbp - GC1_ARG]
    mov edx, 1
    call obj_call_n
    mov [rbp - GC1_TMP], rax
    mov rdi, [rbp - GC1_FN]
    DECREF_V rdi, rcx
    mov rax, [rbp - GC1_TMP]
    leave
    ret
.gc1_fail:
    xor eax, eax
    leave
    ret
END_FUNC gas_call_1

;; ============================================================================
;; gas_subst_nested(rdi = an argument that is still generic,
;;                   rsi = the outer __parameters__, rdx = the outer items)
;;   -> rax = the argument with ITS parameters filled in, owned, or 0
;;
;; A nested alias asks for the items its own __parameters__ name, in its own
;; order -- `dict[T, list[S]][int, str]` hands `list[S]` just the `str`.
;; ============================================================================
GSN_ARG    equ 8
GSN_SUB    equ 16           ; its __parameters__, owned
GSN_ITEMS  equ 24           ; the tuple built for it, owned
GSN_OPARAM equ 32           ; the outer __parameters__, borrowed
GSN_OITEMS equ 40           ; the outer items, borrowed
GSN_FRAME  equ 56           ; + 1 push = 64, 16-aligned
DEF_FUNC_LOCAL gas_subst_nested, GSN_FRAME
    push rbx
    mov [rbp - GSN_ARG], rdi
    mov [rbp - GSN_OPARAM], rsi
    mov [rbp - GSN_OITEMS], rdx
    xor eax, eax
    mov [rbp - GSN_SUB], rax
    mov [rbp - GSN_ITEMS], rax

    CSTRING rsi, "__parameters__"
    call gas_getattr
    test rax, rax
    jz .gsn_keep
    mov [rbp - GSN_SUB], rax
    ; CPython's _Py_subs_parameters substitutes only when __parameters__ "is a
    ; non-empty tuple" and otherwise CARRIES THE ARGUMENT OVER unchanged.  Both
    ; of these used to be failures, so `dict[T, list[int]][str]` -- an ordinary
    ; nested alias with nothing left to substitute -- raised "subscript failed
    ; without an exception" instead of answering dict[str, list[int]].
    lea rcx, [rel tuple_type]
    cmp [rax + PyObject.ob_type], rcx
    jne .gsn_keep
    mov rdi, [rax + PyTupleObject.ob_size]
    test rdi, rdi
    jz .gsn_keep
    call tuple_new
    test rax, rax
    jz .gsn_fail
    mov [rbp - GSN_ITEMS], rax

    xor ebx, ebx
.gsn_loop:
    mov rax, [rbp - GSN_SUB]
    cmp rbx, [rax + PyTupleObject.ob_size]
    jge .gsn_filled
    mov rax, [rax + PyTupleObject.ob_item]
    mov rdi, [rax + rbx*8]
    mov rsi, [rbp - GSN_OPARAM]
    mov rdx, [rbp - GSN_OITEMS]
    call gas_item_for
    test rax, rax
    jz .gsn_fail
    mov rcx, [rbp - GSN_ITEMS]
    mov rcx, [rcx + PyTupleObject.ob_item]
    mov [rcx + rbx*8], rax
    INCREF_V rax, rdx
    inc rbx
    jmp .gsn_loop

.gsn_filled:
    mov rdi, [rbp - GSN_ARG]
    mov rsi, [rbp - GSN_ITEMS]
    call gas_subscript_any
    push rax
    mov rdi, [rbp - GSN_SUB]
    call obj_decref
    mov rdi, [rbp - GSN_ITEMS]
    call obj_decref
    pop rax
    pop rbx
    leave
    ret

.gsn_keep:
    ; Nothing to substitute: hand the argument back as it stands, owned,
    ; because the caller stores what this returns straight into the tuple.
    mov rdi, [rbp - GSN_SUB]
    test rdi, rdi
    jz .gsn_keep_arg
    call obj_decref
.gsn_keep_arg:
    mov rax, [rbp - GSN_ARG]
    INCREF_V rax, rcx
    pop rbx
    leave
    ret

.gsn_fail:
    mov rdi, [rbp - GSN_SUB]
    test rdi, rdi
    jz .gsn_fi
    call obj_decref
.gsn_fi:
    mov rdi, [rbp - GSN_ITEMS]
    test rdi, rdi
    jz .gsn_out
    call obj_decref
.gsn_out:
    xor eax, eax
    pop rbx
    leave
    ret
END_FUNC gas_subst_nested

;; ============================================================================
;; gas_getattr(rdi = an object, rsi = a name cstr) -> rax = the attribute,
;;   owned, or 0 with nothing pending
;; ============================================================================
GGA_NAME  equ 8
GGA_FRAME equ 24            ; + 1 push = 32, 16-aligned
DEF_FUNC_LOCAL gas_getattr, GGA_FRAME
    push rdi
    mov rdi, rsi
    call str_from_cstr_heap
    mov [rbp - GGA_NAME], rax
    pop rdi
    test rax, rax
    jz .gga_no
    mov rsi, rax
    call obj_getattr_opt
    push rax
    mov rdi, [rbp - GGA_NAME]
    call obj_decref
    pop rax
    test rax, rax
    jz .gga_no
    V_TEST_PTR rax, rcx
    ja .gga_drop
    leave
    ret
.gga_drop:
    xor eax, eax
.gga_no:
    leave
    ret
END_FUNC gas_getattr

;; ============================================================================
;; gas_subscript_any(rdi = an object, rsi = a tuple of items) -> rax = the
;;   subscripted object, owned, or 0
;;
;; A nested argument may be one of ours or typing's own Python class, so the
;; mapping slot is tried first and the dunder second -- which is the order
;; op_binary_subscr uses.
;; ============================================================================
DEF_FUNC gas_subscript_any
    mov rax, [rdi + PyObject.ob_type]
    mov rax, [rax + PyTypeObject.tp_as_mapping]
    test rax, rax
    jz .gsa_dunder
    mov rax, [rax + PyMappingMethods.mp_subscript]
    test rax, rax
    jz .gsa_dunder
    leave
    jmp rax
.gsa_dunder:
    call mapping_getitem_opt
    leave
    ret
END_FUNC gas_subscript_any

;; ============================================================================
;; gap_collect() -- one pass over the arguments of the alias
;; generic_alias_parameters parked in its frame.  Counts into GAP_N, and fills
;; GAP_OUT when it is not 0.  Only callable from there.
;;   -> nothing
;; ============================================================================
DEF_FUNC_BARE gap_collect
    push rbx
    push r12
    push r13
    push r14                    ; four, so rsp stays 16-aligned at the calls
    mov r13, [rbp - GAP_SELF]
    mov r13, [r13 + PyGenericAliasObject.ga_args]
    xor r14d, r14d              ; the index into the arguments
.gapc_loop:
    cmp r14, r12
    jge .gapc_done
    ; The argument at r14 -- or the bare object, when there is only one.
    mov rbx, r13
    V_TEST_PTR rbx, rcx
    ja .gapc_have_arg
    lea rcx, [rel tuple_type]
    cmp [rbx + PyObject.ob_type], rcx
    jne .gapc_have_arg
    mov rax, [rbx + PyTupleObject.ob_item]
    mov rbx, [rax + r14*8]
.gapc_have_arg:
    V_TEST_PTR rbx, rcx
    ja .gapc_next
    test rbx, rbx
    jz .gapc_next

    ; A NESTED alias contributes its own parameters, not itself:
    ; list[list[T]].__parameters__ is (~T,) in CPython.  generic_alias_
    ; parameters has a frame of its own, so this recurses, and the tuple it
    ; answers is walked through the same TypeVar test and the same dedup.
    lea rcx, [rel generic_alias_type]
    cmp [rbx + PyObject.ob_type], rcx
    jne .gapc_plain
    mov rdi, rbx
    call generic_alias_parameters
    test rax, rax
    jz .gapc_next
    push rax
    mov r15, rax
    xor ecx, ecx
.gapc_nested:
    cmp rcx, [r15 + PyTupleObject.ob_size]
    jge .gapc_nested_done
    push rcx
    mov rax, [r15 + PyTupleObject.ob_item]
    mov rbx, [rax + rcx*8]
    call gap_take
    pop rcx
    inc rcx
    jmp .gapc_nested
.gapc_nested_done:
    pop rdi
    call obj_decref
    jmp .gapc_next

.gapc_plain:
    ; Is it a TypeVar?  typing asks by __typing_subst__, and so does this.
    mov rdi, rbx
    CSTRING rsi, "__typing_subst__"
    call gap_has_attr
    test eax, eax
    jz .gapc_next
    call gap_take
.gapc_next:
    inc r14
    jmp .gapc_loop
.gapc_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
END_FUNC gap_collect

;; ============================================================================
;; gap_take() -- record the TypeVar in rbx, unless it is already there
;;
;; Counts on the first pass and fills on the second, the way gap_collect
;; does; only callable from generic_alias_parameters' frame.
;;   -> nothing
;; ============================================================================
DEF_FUNC_BARE gap_take
    push rbx
    mov rdi, rbx
    call gap_already
    test eax, eax
    jnz .gapt_done
    mov rax, [rbp - GAP_OUT]
    test rax, rax
    jz .gapt_count
    mov rcx, [rbp - GAP_N]
    mov rax, [rax + PyTupleObject.ob_item]
    mov [rax + rcx*8], rbx
    mov rdi, rbx
    call obj_incref
.gapt_count:
    inc qword [rbp - GAP_N]
.gapt_done:
    pop rbx
    ret
END_FUNC gap_take

;; ============================================================================
;; gap_has_attr(rdi = an object, rsi = a name cstr) -> eax = 1 when it has it
;;
;; hasattr, without leaving an exception behind: obj_getattr_opt answers 0 for
;; a miss and may leave one for a raise, and a probe must not.
;; ============================================================================
GHA_NAME  equ 8
GHA_FRAME equ 24            ; + 1 push = 32, 16-aligned
DEF_FUNC_LOCAL gap_has_attr, GHA_FRAME
    push rdi
    mov rdi, rsi
    call str_from_cstr_heap
    mov [rbp - GHA_NAME], rax
    pop rdi
    test rax, rax
    jz .gha_no
    mov rsi, rax
    call obj_getattr_opt
    push rax
    mov rdi, [rbp - GHA_NAME]
    call obj_decref
    pop rax
    test rax, rax
    jz .gha_clear
    mov rdi, rax
    V_TEST_PTR rdi, rcx
    ja .gha_yes
    call obj_decref
.gha_yes:
    mov eax, 1
    leave
    ret
.gha_clear:
    mov rdi, [gs:ThreadState.current_exception]
    test rdi, rdi
    jz .gha_no
    mov qword [gs:ThreadState.current_exception], 0
    call obj_decref
.gha_no:
    xor eax, eax
    leave
    ret
END_FUNC gap_has_attr

;; ============================================================================
;; gap_already(rdi = a TypeVar) -> eax = 1 when GAP_OUT already holds it
;;
;; By identity, as CPython's does: two TypeVars with the same name are two
;; parameters.  Answers 0 on the counting pass, when there is no tuple yet --
;; which would overcount a repeat, so the counting pass keeps its own guard
;; by walking the arguments it has already passed.
;; ============================================================================
DEF_FUNC_BARE gap_already
    push rbx
    mov rbx, [rbp - GAP_OUT]
    test rbx, rbx
    jz .gapa_scan_args
    mov rcx, [rbp - GAP_N]
    mov rax, [rbx + PyTupleObject.ob_item]
    xor edx, edx
.gapa_loop:
    cmp rdx, rcx
    jge .gapa_no
    cmp [rax + rdx*8], rdi
    je .gapa_yes
    inc rdx
    jmp .gapa_loop
.gapa_scan_args:
    ; The counting pass: look back over the arguments already visited.
    mov rax, [rbp - GAP_SELF]
    mov rax, [rax + PyGenericAliasObject.ga_args]
    V_TEST_PTR rax, rcx
    ja .gapa_no
    lea rcx, [rel tuple_type]
    cmp [rax + PyObject.ob_type], rcx
    jne .gapa_no
    mov rax, [rax + PyTupleObject.ob_item]
    xor edx, edx
.gapa_back:
    cmp rdx, r14
    jge .gapa_no
    cmp [rax + rdx*8], rdi
    je .gapa_yes
    inc rdx
    jmp .gapa_back
.gapa_yes:
    mov eax, 1
    pop rbx
    ret
.gapa_no:
    xor eax, eax
    pop rbx
    ret
END_FUNC gap_already

;; ga_emit_name(rdi = Value, rsi = buffer, rdx = length, r8 = capacity)
;;   -> rax = new length
;; The display form used inside a generic alias or a union: a type shows as
;; its unqualified name, Ellipsis as "...", anything else as its repr.
DEF_FUNC ga_emit_name, 8            ; 3 pushes, so rsp is 16-aligned
    push rbx
    push r12
    push r13
    mov rbx, rsi
    mov r13, rdx
    mov r12, rdi

    lea rax, [rel ellipsis_singleton]
    cmp r12, rax
    jne .gen_not_ellipsis
    cmp r13, 240
    jae .gen_out
    mov byte [rbx + r13], '.'
    mov byte [rbx + r13 + 1], '.'
    mov byte [rbx + r13 + 2], '.'
    add r13, 3
    jmp .gen_out

.gen_not_ellipsis:
    ; NoneType prints as None, in a union and in a subscript alike:
    ; `int | None` and `list[None]` are what CPython spells these.
    lea rax, [rel none_type]
    cmp r12, rax
    jne .gen_not_none
    cmp r13, 240
    jae .gen_out
    mov byte [rbx + r13], 'N'
    mov byte [rbx + r13 + 1], 'o'
    mov byte [rbx + r13 + 2], 'n'
    mov byte [rbx + r13 + 3], 'e'
    add r13, 4
    jmp .gen_out

.gen_not_none:
    V_TEST_PTR r12, rax
    ja .gen_repr
    test r12, r12
    jz .gen_repr
    ; Any class, whichever metatype made it -- a class built by a metaclass of
    ; its own is still a class, and comparing ob_type against the two
    ; metatypes this tree ships answered no for it.
    mov rax, [r12 + PyObject.ob_type]
    test qword [rax + PyTypeObject.tp_flags], TYPE_FLAG_METATYPE
    jz .gen_repr

.gen_typename:
    ; CPython qualifies a class with its module here as it does in a repr:
    ; `__main__.C | None`, and `int | None` for anything in builtins.  The
    ; module comes from the type's dict, and the name is what follows the
    ; last dot of tp_name -- a builtin whose tp_name already carries its
    ; module would otherwise be printed with it twice.
    mov rdi, [r12 + PyTypeObject.tp_dict]
    test rdi, rdi
    jz .gen_no_module
    push rdi
    CSTRING rdi, "__module__"
    extern str_from_cstr
    call str_from_cstr
    pop rdi
    test rax, rax
    jz .gen_no_module
    mov rsi, rax
    extern dict_get
    call dict_get
    test rax, rax
    jz .gen_no_module
    V_TEST_PTR rax, rcx
    ja .gen_no_module
    mov rcx, [rax + PyObject.ob_type]
    lea rdx, [rel str_type]
    cmp rcx, rdx
    jne .gen_no_module
    mov rcx, [rax + PyStrObject.ob_size]
    test rcx, rcx
    jz .gen_no_module
    lea rdi, [rax + PyStrObject.data]
    cmp rcx, 8
    jne .gen_copy_module
    push rax
    push rcx
    CSTRING rsi, "builtins"
    call ap_strcmp
    pop rcx
    pop rax
    test eax, eax
    jz .gen_no_module           ; builtins is left off, as CPython leaves it
    lea rdi, [rax + PyStrObject.data]
.gen_copy_module:
    xor edx, edx
.gen_mod_loop:
    cmp rdx, rcx
    jge .gen_mod_done
    cmp r13, 240
    jae .gen_mod_done
    mov al, [rdi + rdx]
    mov [rbx + r13], al
    inc r13
    inc rdx
    jmp .gen_mod_loop
.gen_mod_done:
    cmp r13, 240
    jae .gen_no_module
    mov byte [rbx + r13], '.'
    inc r13

.gen_no_module:
    mov rsi, [r12 + PyTypeObject.tp_name]
    mov rdi, rsi
    xor ecx, ecx
.gen_last_dot:
    movzx eax, byte [rsi + rcx]
    test al, al
    jz .gen_name_start
    cmp al, '.'
    jne .gen_dot_next
    lea rdi, [rsi + rcx + 1]
.gen_dot_next:
    inc rcx
    jmp .gen_last_dot
.gen_name_start:
    mov rsi, rdi
.gen_name_copy:
    movzx eax, byte [rsi]
    test al, al
    jz .gen_out
    inc rsi
    cmp r13, 240
    jae .gen_out
    mov [rbx + r13], al
    inc r13
    jmp .gen_name_copy

.gen_repr:
    mov rdi, r12
    call obj_repr
    V_UNPACK rax, rdx
    test rax, rax
    jz .gen_out
    push rax
    mov r8, [rax + PyStrObject.ob_size]
    lea rsi, [rax + PyStrObject.data]
    xor ecx, ecx
.gen_repr_copy:
    cmp rcx, r8
    jge .gen_repr_done
    cmp r13, 240
    jae .gen_repr_done
    movzx eax, byte [rsi + rcx]
    mov [rbx + r13], al
    inc r13
    inc rcx
    jmp .gen_repr_copy
.gen_repr_done:
    pop rdi
    call obj_decref

.gen_out:
    mov rax, r13
    pop r13
    pop r12
    pop rbx
    leave
    ret
END_FUNC ga_emit_name


;; ============================================================================
;; generic_alias_hash(rdi = self) -> rax = hash
;; generic_alias_richcompare(rdi = left, rsi = right, edx = op) -> Value
;;
;; union_type got both of these and generic_alias_type did not, so
;; `{list[int]: 1}[list[int]]` was a KeyError: two aliases spelt the same way
;; hashed by identity and compared by it.  Unlike a union, an alias is ordered
;; -- list[int, str] is not list[str, int] -- so this is a plain combine over
;; (origin, args) rather than union's set equality.
;; ============================================================================
GAH_FRAME equ 16            ; + 2 pushes = 32

DEF_FUNC generic_alias_hash, GAH_FRAME
    push rbx
    push r12
    mov rbx, rdi
    mov rdi, [rbx + PyGenericAliasObject.ga_origin]
    test rdi, rdi
    jz .gah_no_origin
    call obj_hash
    jmp .gah_have_origin
.gah_no_origin:
    xor eax, eax
.gah_have_origin:
    mov r12, rax
    mov rdi, [rbx + PyGenericAliasObject.ga_args]
    test rdi, rdi
    jz .gah_done
    call obj_hash
    imul r12, r12, 1000003
    xor r12, rax
.gah_done:
    mov rax, r12
    cmp rax, -1
    jne .gah_ret
    mov rax, -2
.gah_ret:
    pop r12
    pop rbx
    leave
    ret
END_FUNC generic_alias_hash

;; ============================================================================
;; generic_alias_richcompare(rdi = left, rsi = right, edx = op) -> Value
;;
;; The other half of the pair documented above hash: an alias is ORDERED, so
;; equality is origin-then-args in order, and every other op declines.
;; ============================================================================
GRC_LEFT  equ 8
GRC_RIGHT equ 16
GRC_OP    equ 24
GRC_FRAME equ 32            ; + 0 pushes = 32

DEF_FUNC generic_alias_richcompare, GRC_FRAME
    cmp edx, PY_EQ
    je .grc_ok
    cmp edx, PY_NE
    jne .grc_decline
.grc_ok:
    mov [rbp - GRC_OP], edx
    ; Both sides must be aliases; anything else declines so the protocol can
    ; try the other operand.
    V_TEST_PTR rdi, rax
    ja .grc_decline
    V_TEST_PTR rsi, rax
    ja .grc_decline
    mov rax, [rdi + PyObject.ob_type]
    lea rcx, [rel generic_alias_type]
    cmp rax, rcx
    jne .grc_decline
    mov rax, [rsi + PyObject.ob_type]
    cmp rax, rcx
    jne .grc_decline
    mov [rbp - GRC_LEFT], rdi
    mov [rbp - GRC_RIGHT], rsi

    mov rdi, [rdi + PyGenericAliasObject.ga_origin]
    mov rsi, [rsi + PyGenericAliasObject.ga_origin]
    mov edx, PY_EQ
    extern obj_richcompare_bool
    call obj_richcompare_bool
    test eax, eax
    jl .grc_raised
    test eax, eax
    jz .grc_false

    mov rdi, [rbp - GRC_LEFT]
    mov rdi, [rdi + PyGenericAliasObject.ga_args]
    mov rsi, [rbp - GRC_RIGHT]
    mov rsi, [rsi + PyGenericAliasObject.ga_args]
    mov edx, PY_EQ
    call obj_richcompare_bool
    test eax, eax
    jl .grc_raised
    test eax, eax
    jz .grc_false

    mov eax, 1
    jmp .grc_answer
.grc_false:
    xor eax, eax
.grc_answer:
    cmp dword [rbp - GRC_OP], PY_NE
    jne .grc_emit
    xor eax, 1
.grc_emit:
    test eax, eax
    jz .grc_emit_false
    lea rax, [rel bool_true]
    jmp .grc_emit_done
.grc_emit_false:
    lea rax, [rel bool_false]
.grc_emit_done:
    inc qword [rax + PyObject.ob_refcnt]
    mov edx, TAG_PTR
    leave
    V_PACK rax, rdx
    ret
.grc_decline:
    xor eax, eax                ; a NULL Value: NotImplemented
    xor edx, edx
    leave
    ret
.grc_raised:
    xor eax, eax
    xor edx, edx
    leave
    ret
END_FUNC generic_alias_richcompare

section .data

align 8
; PEP 585's parameter substitution is a MAPPING subscript, which is the first
; slot op_binary_subscr reads -- so `list[T][int]` needs no opcode change,
; only somewhere to put mp_subscript.  Modelled on generic_alias_as_number,
; which is the same shape one slot over.
generic_alias_as_mapping:
    dq 0                            ; mp_length
    dq generic_alias_subscript      ; mp_subscript
    dq 0                            ; mp_ass_subscript

align 8
global generic_alias_type
generic_alias_type:
    dq 1                            ; ob_refcnt (immortal)
    dq type_type                    ; ob_type
    dq ga_name_str                  ; tp_name
    dq PyGenericAliasObject_size    ; tp_basicsize
    dq generic_alias_dealloc        ; tp_dealloc
    dq generic_alias_repr           ; tp_repr
    dq generic_alias_repr           ; tp_str
    dq generic_alias_hash           ; tp_hash
    dq generic_alias_call           ; tp_call
    dq generic_alias_getattr        ; tp_getattr
    dq 0                            ; tp_setattr
    dq generic_alias_richcompare    ; tp_richcompare
    dq generic_alias_iter           ; tp_iter
    dq 0                            ; tp_iternext
    dq 0                            ; tp_init
    dq generic_alias_construct      ; tp_new
    dq generic_alias_as_number      ; tp_as_number
    dq 0                            ; tp_as_sequence
    dq generic_alias_as_mapping     ; tp_as_mapping
    dq 0                            ; tp_base
    dq 0                            ; tp_dict
    dq 0                            ; tp_mro
    dq 0                            ; tp_flags
    dq 0                            ; tp_bases
    dq 0                            ; tp_traverse
    dq 0                            ; tp_clear
    dq 0                            ; tp_dictoffset
    dq 0                        ; tp_tailslots
    dq 0                        ; tp_as_buffer
