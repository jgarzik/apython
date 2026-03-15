# Bug Log - CPython Container Test Import

## Bugs Found & Fixed

### 1. Negative-step slicelength missing guard (list.asm, tuple.asm)
**Symptom**: `a[3:3:-2]` causes OOM (allocates huge array)
**Root cause**: Negative step slicelength formula `(start-stop-1)/abs(step)+1` used unsigned div without checking `start <= stop` first. When start==stop, `start-stop-1 = -1 = 0xFFFFFFFFFFFFFFFF` unsigned.
**Fix**: Add `jle .empty` guard after `sub rax, r14` in both list and tuple getslice.

### 2. slice_indices start/stop clamping for negative step (slice.asm)
**Symptom**: `a[100:-100:-1]` segfaults (out-of-bounds read)
**Root cause**: `start >= length` clamped to `length` for all steps, but negative step needs `length-1`. `stop < 0` after adding length clamped to 0 for all steps, but negative step needs `-1`.
**Fix**: Conditional clamping based on step sign, matching CPython's PySlice_AdjustIndices.

### 3. slice_indices NONE_SENTINEL collision with sys.maxsize (slice.asm)
**Symptom**: `a[1::sys.maxsize]` treats step as None (defaults to 1)
**Root cause**: NONE_SENTINEL = 0x7FFFFFFFFFFFFFFF == sys.maxsize. When step = sys.maxsize, the comparison `cmp rax, NONE_SENTINEL` matched and step was treated as None.
**Fix**: Check actual payload against `none_singleton` pointer AND tag for `TAG_NONE` or `TAG_PTR` with None, instead of comparing integer values.

### 4. `del a[i]` not decrementing ob_size (list.asm)
**Symptom**: `del a[1]` on `[0, 1]` gives `[0, ]` (size still 2, second slot cleared)
**Root cause**: `list_ass_subscript` with value=NULL always called `list_setitem` which replaces the slot with NULL but doesn't remove it or update size.
**Fix**: Add `.las_int_delete` path that DECREFs old, shifts elements via memmove, decrements `ob_size`.

### 5. `list[string_key]` segfault (list.asm, tuple.asm)
**Symptom**: `a['x']` segfaults instead of raising TypeError
**Root cause**: `list_subscript` assumed non-SmallInt, non-slice keys were heap ints and called `int_to_i64` on them, crashing on strings.
**Fix**: Check `ob_type == int_type` before calling `int_to_i64`; raise TypeError otherwise.

### 6. list.index() ignoring start/stop parameters (methods.asm)
**Symptom**: `[-2,-1,0,0,1,2].index(0, 3)` returns 2 instead of 3
**Root cause**: `list_method_index` always searched from index 0 regardless of nargs.
**Fix**: Check nargs >= 3/4 and extract start/stop from args[2]/args[3] with negative index handling.

### 7. tuple*int dispatch missing (opcodes_misc.asm)
**Symptom**: `(1,2)*2` raises TypeError
**Root cause**: BINARY_OP only checked right operand for sq_repeat when left was SmallInt. When left was a sequence (tuple/list) and right was SmallInt, it fell through to tp_as_number which is NULL for tuples.
**Fix**: Add `.binop_try_left_seq` check in `.binop_not_smallint_left` path.

### 8. tuple+tuple dispatch missing (opcodes_misc.asm)
**Symptom**: `(1,2) + (3,4)` raises TypeError
**Root cause**: BINARY_OP for NB_ADD only checked tp_as_number, not tp_as_sequence.sq_concat.
**Fix**: Add `.binop_try_seq_fallback` that checks sq_concat for ADD and sq_repeat for MULTIPLY when tp_as_number is NULL.

### 9. list_inplace_repeat tag realloc using wrong size (list.asm)
**Symptom**: `s *= 10` corrupts memory / changes list identity
**Root cause**: After payload `ap_realloc` (which returns new ptr in rax), the tag realloc used `rax` (the pointer!) as the size instead of the actual new_size from the stack.
**Fix**: `mov rsi, [rsp]` to load new_size from stack instead of `mov rsi, rax`.

### 10. list_inplace_multiply dispatched to sq_repeat (opcodes_misc.asm)
**Symptom**: `s *= 10` changed list identity (`id(s)` differed after)
**Root cause**: NB_INPLACE_MULTIPLY was dispatched to sq_repeat (creates new object) instead of nb_imul/sq_inplace_repeat (mutates in place).
**Fix**: Remove NB_INPLACE_MULTIPLY from the left-seq sq_repeat dispatch; let it fall through to nb_imul.

### 11. List extended slice self-assignment corruption (list.asm)
**Symptom**: `a[::-1] = a` gives `[0, 1, 1, 0]` instead of `[3, 2, 1, 0]`
**Root cause**: Extended slice loop reads from source and writes to target simultaneously; when source == target, writes corrupt subsequent reads.
**Fix**: Detect self-assignment (`r12 == rbx`), create shallow copy via `list_copy()`, use copy as source. Store copy in LAS_TEMP for cleanup.

### 12. List step-1 slice self-assignment corruption (list.asm)
**Symptom**: `a[1:] = a` gives `[1, 1, 1, 1, 1, 1]` instead of `[1, 1, 2, 3, 4, 5]`
**Root cause**: Same as #11 but for the step-1 path. Also: `call list_copy` clobbered `rcx` (old_len).
**Fix**: Self-assignment detection + `list_copy` + save/restore `rcx` around the call.

### 13. Exhausted list iterator not marked (iter.asm, opcodes_build.asm)
**Symptom**: `list(exhausted_iter)` picks up newly-appended elements
**Root cause**: `FOR_ITER_LIST` specialized opcode didn't mark iterators as exhausted (set `it_seq = NULL`) when done. Only the generic `list_iter_next` path did.
**Fix**: Add `it_seq = NULL` + DECREF in `FOR_ITER_LIST`'s `.fil_exhausted` path. Guard dealloc against NULL `it_seq`.

### 14. tuple.index() ignoring start/stop parameters (methods.asm)
**Symptom**: Same as #6 but for tuples
**Fix**: Same pattern as list.index - check nargs, extract start/stop.

### 15. set_richcompare completely unimplemented (set.asm)
**Symptom**: `{1,2} == {1,2}` returns False, `set() == set()` returns False
**Root cause**: `tp_richcompare = 0` for set_type and frozenset_type. The `==` operator fell through to identity comparison.
**Fix**: Implement `set_richcompare` for PY_EQ and PY_NE. PY_EQ checks len equality then verifies every element of self is in other. PY_NE negates PY_EQ result.

### 16. dict() constructor creates broken dict (dict.asm)
**Symptom**: `dict() == {}` returns False, adding items to `dict()` crashes with "hash table full"
**Root cause**: `dict_type.tp_call = 0`, so `type_call` used generic `instance_new` which allocated a PyDictObject-sized block but didn't initialize the hash table entries array.
**Fix**: Implement `dict_type_call` that calls `dict_new` for no-args case and copies entries for dict(other_dict) case.

### 17. dict.update() no-args crash (methods.asm)
**Symptom**: `d.update()` segfaults
**Root cause**: Always reads `args[1]` without checking nargs first
**Fix**: Add `cmp rsi, 1; jle .du_done` guard at start

### 18. dict.popitem() key tag hardcoded to TAG_PTR (methods.asm)
**Symptom**: `d.popitem()` segfaults on dicts with non-string keys
**Root cause**: Key tag hardcoded to TAG_PTR, `INCREF` used instead of `INCREF_VAL`, key tag not read from entry
**Fix**: Read key_tag from entry, use INCREF_VAL, pass correct tag to dict_del

### 19. set.update() method missing (methods.asm)
**Symptom**: `s.update({3,4})` raises AttributeError
**Root cause**: Method not implemented, not registered in set tp_dict
**Fix**: Implement set_method_update, register in init_builtin_methods

### 20. dict_keys_equal only handles strings/numerics (dict.asm)
**Symptom**: `d[(2,)]` fails to find key even though `(2,)` is in dict (memoize pattern broken)
**Root cause**: `dict_keys_equal` returned "not equal" for any non-string, non-numeric heap pointers. Tuple keys, frozenset keys, etc. all failed equality checks.
**Fix**: Add `.dke_try_richcompare` fallback that calls `tp_richcompare(PY_EQ)` + `obj_is_true` for non-string heap pointer keys.

### 21. assertRaises double-free on fn(*args) exception (opcodes_call.asm)
**Symptom**: `assertRaises(ValueError, bad)` crashes with double-free
**Root cause**: CALL_FUNCTION_EX freed cfex_temp_pending, then eval_exception_unwind freed it again
**Fix**: Clear cfex_temp_pending before the call, not after

### 22. list `in` operator doesn't call reflected __eq__ (list.asm)
**Symptom**: `ALWAYS_EQ in [1]` returns False
**Root cause**: list_contains only tried element's __eq__, not value's reflected __eq__
**Fix**: Added `.try_reflected` path in list_contains

### Known Bugs Not Yet Fixed
- `dict.update(x=1, y=2)` with kwargs segfaults (methods.asm)
- `repr(d.keys())` returns wrong value (dict view repr not implemented)
- `(1,1) in d.items()` fails (dict_items __contains__ not implemented)
- `tuple(t) is t` identity optimization not implemented
- `list.append()` no-args segfaults (method arg count validation missing)
- `assertRaises(fn)` double-free crash (exception handling memory issue)
- `issubclass(C, (C,))` always returns False (tuple arg not supported)
- `isinstance(1, 1)` doesn't raise TypeError (input validation missing)
- `issubclass(1, int)` segfaults (input validation missing)
- `func.__name__ = "x"` silently ignored (attribute set on functions not supported)

## New Infrastructure Added
- `list_copy()` - standalone shallow copy function
- `ALWAYS_EQ`, `NEVER_EQ`, `C_RECURSION_LIMIT` in `lib/test/support/__init__.py`
- `lib/test/seq_tests.py` - adapted base test class
- `lib/test/list_tests.py` - adapted list test class
