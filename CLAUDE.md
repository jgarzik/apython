# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Python 3.12 implementation in x86-64 NASM assembly: a bytecode interpreter, and
a compiler for the source language written in the same assembly.  Reads `.py`
through `src/compiler/`, or `.pyc` through the marshal reader.

The standard library is CPython's own: `stdlib/` is CPython 3.12's `Lib/`,
unmodified, copied by `tools/vendor_stdlib.sh` (the tag is in
`stdlib/VENDORED`).  What CPython writes in C is assembly here, or Python in
`lib/`, which comes AFTER `stdlib/` on `sys.path` so nothing in it can shadow
a CPython module.  Never edit `stdlib/`; re-vendor it.

## Build & Test

```bash
make              # build ./apython
make clean        # remove build/ and apython
make check        # full test suite: compile .py→.pyc, diff python3 vs ./apython output,
                  #   then tests/pyc_probe.sh over a set of crafted .pyc files
make check-cpython # CPython stdlib unit tests (harder, more thorough)
make check-stdlib # how much of a CPython 3.12 Lib/ imports; a ratchet
make check-source # the whole corpus compiled by OUR compiler; a ratchet
make regen        # regenerate the machine-written asm (needs CPython 3.12)
make check-cpython-source  # the CPython corpus, compiled by OUR compiler
```

```bash
./apython --selftest-compile   # source-compiler invariants and tokenizer
./apython --selftest-alloc     # the pool allocator, without the interpreter
python3 src/compiler/lint.py   # static checks over the assembly
```

**Always run BOTH `make check` AND `make check-cpython` to verify changes.**

`make check-stdlib` needs a CPython source checkout; point `$CPYTHON_LIB` at
its `Lib/` (default `~/tmp/repo/cpython/Lib`).  It compares against
`tests/stdlib_floor.txt` and fails when a module that used to import stops, or
when a new one crashes.  Raise the floor with
`bash tests/stdlib_probe.sh --record` in the commit that earns it.
`make check` runs every `tests/test_*.py`, then `tests/pyc_probe.sh` and
`tests/arity_probe.sh`.  A test listed in `tests/known_failures.txt` is
reported XFAIL, with the reason and the phase that fixes it written beside
it, and FAILS the run if it starts passing -- so the entry leaves in the
commit that earns it.  `make check-cpython` runs everything under
`tests/cpython/`, none of it tolerated as failing.

`make check-source` and `make check-cpython-source` hand apython the `.py`
instead of the `.pyc`, so our own compiler produces the bytecode.  They are the
only things that exercise the compiler on a large body of ordinary code -- most
of its bugs were found there rather than by a test written for them, including
several that need a whole file rather than a snippet to appear at all.  They
also reach interpreter paths a `.pyc` cannot, because CPython's constant folder
settles `3 * "ab"`, `True & False` and `-7 // 2` before any of them becomes an
opcode.

They use different oracles, because their corpora differ.  `check-source` diffs
against `python3`: those tests print, and CPython is the reference.
`check-cpython-source` diffs against **the same file run from its `.pyc`** --
same interpreter, same `unittest`, and the only difference is which
compiler produced the bytecode.  It cannot use `python3`: this corpus drives our
own `unittest`, whose progress output differs by design, and two of its files
import `test.seq_tests` / `test.test_grammar`, which ship in `lib/` and which a
system CPython cannot find.

Neither gate compares bytecode.  Two compilers may fold and order differently
and both be right, so that would measure style rather than correctness;
comparing the *behaviour* of the programs they produce is immune to it, except
in a narrow band where a compiler's choices are legitimately observable --
identity of constants one side folds (`"ab" * 3 is "ababab"` is True from
CPython's `.pyc`, False from ours, and neither is wrong), code-object
introspection, traceback text, and compile-time error wording.  Triage a newly
differing file against that band before calling it a regression; the script
header lists it in full.

`check-cpython-source` is the harder of the two: that corpus is CPython's own
and written to be adversarial.  Every file in it matches -- a claim that, until
2026-08-31, had never actually been tested, because the probe only checked the
exit status.  Each ratchets against a floor file
(`tests/compile_floor.txt`, `tests/cpython_source_floor.txt`); raise one with
`bash tests/source_probe.sh --record` or
`bash tests/cpython_source_probe.sh --record` in the commit that earns it.

Two more gates worth running when touching the value representation:

```bash
./apython --selftest-value      # encode/decode boundaries: +-2^50, +-0.0, inf, NaN, subnormals
make INT_STRESS=1 && bash tests/run_tests.sh
```

`INT_STRESS=1` boxes every integer with `|n| >= 8` onto the heap, so the
ordinary suite exercises the heap-int paths that ±2^50 immediates normally
hide.  It is not expected to pass `check-cpython` (CPython's own test_int
asserts things like `10 is 10`).

Until 2026-08-31 this command did nothing: the flag reached `NASMFLAGS` but no
object depended on it, so after an ordinary `make` it relinked the *unstressed*
binary and the run proved nothing.  Objects now depend on `build/.flags`.  Its
first real run found a bug immediately -- the item arm of
`bytes()`/`bytearray()` over an iterable tested `V_IS_INT` and so accepted an
int *immediate* only.

**Single test:**
```bash
python3 -m py_compile tests/test_foo.py
python3 tests/test_foo.py > /tmp/expected.txt
./apython tests/__pycache__/test_foo.cpython-312.pyc > /tmp/actual.txt
diff /tmp/expected.txt /tmp/actual.txt
```

**Dependencies:** nasm, gcc (linker), libgmp-dev, zlib1g-dev, libbz2-dev,
liblzma-dev, libssl-dev, libexpat1-dev, libffi-dev, python3.12

## Register Convention (eval loop)

Callee-saved registers hold global interpreter state:

| Register | Role |
|----------|------|
| `rbx` | Bytecode IP (into co_code[]) |
| `r12` | Current frame (PyFrame*) |
| `r13` | Value stack top (Value[], one 64-bit word per slot) |
| `r14` | co_consts data ptr (&tuple.ob_item[0]) |
| `r15` | Free — scratch for handlers |
| `ecx` | Opcode arg on handler entry |

co_names is accessed via the `LOAD_CO_NAMES reg` macro (reads `ThreadState.eval_co_names` through gs), not a dedicated register.

## Per-thread state (gs)

Everything the interpreter keeps per thread -- `current_exception`,
`handled_exception`, `eval_saved_r12` (the running frame), `eval_base_rsp`, the `*_pending` words, the recursion
counters, the frame data stack, the repr/traceback cycle guards, the trace
hooks and the asyncio loop -- is a field of `struc ThreadState` in
`src/include/threadstate.inc`, reached through the gs segment base:
`mov rax, [gs:ThreadState.current_exception]`.  `main` points gs at
`main_tstate` (`tstate_install`, src/eval.asm) before anything else runs.
`lea` does NOT apply the segment base: a field whose address is wanted is
`[gs:ThreadState.ts_self]` plus the field offset, and an array field is
indexed in place (`[gs:ThreadState.tb_seen + rdx*8]`).  Shared state --
allocator, freelists, the collector, caches, interned strings -- stays an
ordinary `[rel ...]` global.

DISPATCH does NOT go through gs: it publishes the IP and value stack top into
the running frame, `[r12 + PyFrame.disp_ip]` / `[r12 + PyFrame.disp_sp]`, and
the unwinder reads them back from the frame `ThreadState.eval_saved_r12`
names.  Code that republishes r13 for the unwinder and cannot be sure r12 is
still the frame uses `PUBLISH_SP` (macros.inc).  A gs-relative access has about
twice the load latency and half the store rate of a plain one on the machine
this was measured on, so gs is for cold paths and for loading `ts_self` once.

**Critical rule:** Never hold live values in caller-saved regs (rax, rcx, rdx, rsi, rdi, r8-r11) across `call` or `DECREF`/`DECREF_REG`. Use push/pop or callee-saved regs instead. `DECREF_REG` calls `obj_dealloc` which clobbers all caller-saved regs.

## Value Representation (NaN boxing)

**One 64-bit word per Python value.** The encoding lives in `src/include/value.inc`;
`src/val.asm` holds the rip-relative constant pool it compares against, and
`./apython --selftest-value` exercises the boundaries.

Let `high16 = v >> 48`:

| `high16` | Meaning | Decode |
|---|---|---|
| `0x0000` | `PyObject*`, stored **raw** (`v == 0` is NULL) | use as-is |
| `0x0001`–`0xFFF1` | float64 | `bits = v - V_F64_OFF` (2^48) |
| `0xFFF2` | async SLEEP sentinel | `delay_ns = v & V_MASK48` |
| `0xFFF3` | async IO_WAIT sentinel | `fd \| dir<<32 = v & V_MASK48` |
| `0xFFF4`–`0xFFF7` | reserved | — |
| `0xFFF8`–`0xFFFF` | int immediate, range ±2^50 | `i = v - V_INT_BIAS` |

Linux x86-64 user addresses are below 2^47, so a pointer needs no masking and
`NULL == 0` still works with a plain `test`.  Doubles pay one add on the way in
and one sub on the way out; negative NaNs at or above `V_NAN_LIM` (x86's default
QNaN among them) are canonicalised to `0x7FF8000000000000` first, which CPython
cannot observe.  Integers outside ±2^50 are boxed into a `PyIntObject`, which
carries a compact `ival` and only initialises its `mpz_t` on overflow.

None, True and False are the ordinary heap singletons — a pointer is its own
Value, so they need no encoding of their own.

Everything stores one word: the value stack (`r13`), `localsplus`, `ob_item` for
list and tuple, `DictEntry.key`/`.value`, the per-object fields, and the
`tp_call` argument array.

Classification macros (all in `src/include/value.inc`): `V_TEST_PTR`, `V_IS_INT`,
`V_IS_FLOAT`, and the `_M` variants that take a memory operand.  Conversion:
`V_FROM_F64` / `V_TO_F64`, `V_PACK_I64` / `V_TO_I64`.  Refcounting: `INCREF_V`,
`DECREF_V`, `XDECREF_V` — one compare and one branch, NULL-safe.

`V_PACK` / `V_UNPACK` convert to and from the old `(payload, tag)` pair.  They
are migration scaffolding: the tags (`TAG_NULL`, `TAG_SMALLINT`, `TAG_FLOAT`,
`TAG_PTR`, …) survive only inside functions that have not been converted yet,
and at the boundaries between converted and unconverted code.

## Bugs and divergences

`bugs.md` is what is still wrong.  `DIVERGENCES.md` is what differs from
CPython on purpose, with the reasoning and the cost of changing it -- a
behaviour recorded there is not a bug to fix.  Reproduce an entry before
working it; several have drifted.

## Source Layout

No hand-written file exceeds 100k bytes; only generated asm may.
`src/compiler/lint.py` checks it.

- `src/eval.asm` — Bytecode dispatch loop (256-entry jump table), the
  exception unwinder, and `raise_exception`
- `src/opcodes/*.asm` — Opcode handlers by category: `load` (the loads, the
  attribute protocol they share, and the pure stack shuffles), `store` (the
  stores and the deletes), `call`, `build`, `unpack` (UNPACK_SEQUENCE and
  UNPACK_EX, the two that take a sequence apart), `arith` (BINARY_OP/
  COMPARE_OP/unary and the specialized int/float superinstructions), `flow`
  (returns, jumps, f-strings, generators), `match` (the MATCH_* family and the
  intrinsics), `async`, `import`
- `src/methods/*.asm` — Builtin type methods, one file per type: `str`,
  `str_pred`, `str_parts`, `list`, `tuple`, `dict`, `set`, `num`, `bytes`,
  `bytearray_methods` (bytearray's share of bytes' bodies, each run over a
  temporary bytes),
  `object` (object's own dunders plus the `DEF_DUNDER_*` generators), and
  `init`, which registers them all into each type's `tp_dict`.  These share
  basenames with `src/pyo/` on purpose: `methods/dict.asm` is dict's methods,
  `pyo/dict.asm` is dict itself.  `list_sort.asm` is the timsort engine
  `list.sort` drives -- run detection, minrun, the run stack, galloping and
  the comparator the pre-sort type scan chooses; `methods/list.asm` keeps
  everything around it, and `src/include/listsort.inc` is the MergeState
  layout the two share
- `lib/_imp.py` and `lib/_warnings.py` — the import system's own primitives
  and the warning machinery's C half, which CPython's `importlib._bootstrap`
  is written against.  Neither needs to be assembly: one thread means the
  import lock is a counter, there are no frozen or extension modules, and
  `source_hash` is CPython's siphash13 in Python
- `lib/_md5.py`, `lib/_sha1.py`, `lib/_sha2.py`, `lib/_sha3.py` and
  `lib/_blake2.py` — the digests in Python, which is what `hashlib` reaches
  for when there is no `_hashlib` and what `_blake2` is used for even when
  there is.  `_sha3` is one sponge over Keccak-f[1600]; `_blake2` carries the
  whole parameter block, and its constructors have to be CLASSES because
  callers read `MAX_DIGEST_SIZE` and three more limits off the constructor.
  All five carry an `_Immutable` metaclass, because CPython's are C types and
  `test_hashlib` asserts the type cannot be written to
- `lib/_typing.py` — the objects PEP 695's syntax builds: TypeVar, ParamSpec,
  TypeVarTuple, TypeAliasType and Generic.  Reached from the
  `CALL_INTRINSIC_1`/`_2` handlers in `src/opcodes/match.asm`, the same split
  `_iocore`/`_io` and `_socketcore`/`_socket` use
- `src/modules/*.asm` — one file per built-in module, named for the module:
  `errno.asm`, `gc.asm`, `io.asm`, `math.asm`, `posix.asm` (+ `posixproc.asm`),
  `signal.asm`, `socket.asm`, `sre.asm`, `zlib.asm`.  `table.asm` is the list
  every one of them is registered from -- `import_init` and
  `sys.builtin_module_names` both read it, and they used to disagree
- `src/pyo/exc_oserror.asm` — what OSError does that no other exception does:
  the constructor that rewrites its own class from the errno, the four named
  attributes beside `.args`, the message assembled from them, and CPython's
  errno-to-subclass table
- `src/pyo/exc_str.asm` — how an exception renders itself: `repr()` and
  `str()` for every exception, plus the two that are not the general case --
  SyntaxError, which shows the file, the line and a caret before it says what
  was wrong, and UnicodeError, whose `str()` is assembled from five named
  attributes rather than from `.args`.  Split off when `exception.asm` reached
  the 100k cap; what stayed is the exception ITSELF -- the type table,
  construction, teardown, attribute access and the methods
- `src/pyo/*.asm` — Type implementations (int, str, list, dict, tuple, func,
  class, iter, singleton, bytes, bytearray, memoryview, code).
  `dict_views.asm` is the three view types `dict.keys()`, `.values()` and
  `.items()` return, and everything only they do; `dict.asm` is the table.
  Split off when `dict.asm` reached the 100k cap.
  `bytes_decode.asm` is bytes -> str and why it sometimes cannot be: the three
  codecs that are not a table, the UTF-8 validator under them, and the
  UnicodeDecodeError worded the way CPython words it.  Split off when
  `bytes.asm` reached the 100k cap; what stayed is bytes *itself*.  `class.asm` is
  the class and the instance -- construction, the reprs, dealloc and the
  collector's view of both -- while `typeattr.asm` is reading and writing a
  class's attributes, `type_getattr` included.  Split off when `class.asm`
  reached the 100k cap a second time.  `instance_alloc.asm` is
  where an instance comes from, including the constructors a subclass of a
  builtin needs; `method.asm` is the bound method; `str_mod.asm` is the `%`
  operator, for str and for bytes both -- the conversion is only known there,
  so the argument is converted there.  `asyncgen.asm` is the three objects an
  async generator hands out -- the asend and athrow awaitables and the box each
  `yield` arrives in -- and what drives them; `generator.asm` is the generator,
  the coroutine and the async generator themselves.  Split off when
  `generator.asm` reached the 100k cap
- `src/marshal.asm` — .pyc marshal deserializer, the .pyc file reader, and
  the `marshal` module `importlib` calls `loads` on.  `src/marshalw.asm` is
  the other direction: the output buffer, the writers, the identity memo
  FLAG_REF needs on the way out, `dumps`/`dump`/`load`, and
  `pyc_write_cache`, which is what puts a `__pycache__` entry beside a `.py`
  the first time it is imported
- `src/main.asm` — argument parsing, startup order, and the `-t`/`--dis` modes
- `src/import.asm` — the C half of `import`, as CPython splits it: name
  resolution, the `sys.modules` fast path, the dotted walk and IMPORT_FROM's
  fallback.  A miss goes to CPython's own importlib
  (`importlib._bootstrap._find_and_load`) through `lib/_importlib_bootstrap.py`,
  which `main` runs before `site` -- so meta_path, path hooks, specs, loaders,
  zipimport and importlib.metadata are CPython's code.  The assembly finders
  remain only for what loads before importlib exists, and for builtins:
  `src/modules/impcore.asm` is `_impcore`, whose `create_builtin` is where
  BuiltinImporter ends up.  Bytecode is cached under the `apython-312` tag
  only, and `make` precompiles `stdlib/` and `lib/` with apython itself
- `src/modules/io.asm` — the `_iocore` module: the four `_IOBase` types the rest
  of the I/O stack subclasses, `UnsupportedOperation`, `FileIO` and `BytesIO`.
  The buffering and text layers are `lib/_io.py`, which assembles both halves
  under the name `_io`
- `src/modules/posix.asm` / `src/modules/posixproc.asm` — the `posix` module: the file and
  directory syscalls in the first, and everything that makes a second process
  -- fork, execv, _exit, kill, setsid and PEP 3143's fork hooks -- in the
  second.  `lib/_posixsubprocess.py` builds `subprocess`'s fork_exec on them.
  `src/modules/posixpath.asm` is how an ARGUMENT becomes a path -- str, str
  subclass, bytes, bytes subclass or one `__fspath__` step, with the embedded
  NUL refused before the kernel sees it -- split off when `posix.asm` reached
  the 100k cap, along the seam every syscall wrapper already begins at.  It is
  not only posix's: `_io.FileIO` opens from there too, which is what makes
  `open(b"...")` and `open()` of a str subclass work.  `src/include/posixpath.inc`
  is the private ABI the two halves share.  `src/modules/posixfd.asm` is the
  two descriptor calls that are neither a read nor a write, `fcntl` and
  `flock`; `lib/fcntl.py` puts the constants and `lockf` on top, and
  `lib/resource.py` sits the same way on `posix.prlimit` and
  `posix.getrusage` in `posixproc.asm`
- `src/modules/unicodenorm.asm` — UAX #15: the four normal forms and
  `decomposition()`, over the generated `unicodenorm_tables.asm`.  One engine
  serves two DATABASES -- the current one and the frozen Unicode 3.2 copy
  `unicodedata.ucd_3_2_0` exposes -- because they differ only in their table
  contents; `src/modules/ucd32.asm` is the module object the second hangs on,
  and the run properties it answers go through `unicodedata.asm`'s own
  `udp_run_lookup`
- `src/modules/zlib.asm` — the `_zlibcore` module: libz's z_stream, the output
  buffer that grows while deflate writes into it, and the handle table.  A
  shim over `-lz`, on the precedent `-lgmp` set; `lib/zlib.py` is the module
  surface -- the Compress and Decompress objects, the constants, `zlib.error`
  and every default -- so each core call takes fixed positional arguments
- `src/modules/bz2.asm` — the `_bz2core` module: libbzip2's bz_stream, the
  output buffer that grows while the codec writes into it, and the handle
  table.  A shim over `-lbz2`, the same split again: `lib/_bz2.py` is the
  BZ2Compressor and BZ2Decompressor objects CPython's own `bz2.py` is written
  against.  Two things about libbzip2 to know: `BZ_RUN` with no input left
  answers `BZ_PARAM_ERROR` rather than doing nothing, because "no progress"
  and "bad call" share a code there; and `avail_in`/`avail_out` are 32-bit
  while the buffers need not be
- `src/modules/lzma.asm` — the `_lzmacore` module: liblzma's lzma_stream, the
  filter chain and its option structs, and the handle table.  A shim over
  `-llzma`; `lib/_lzma.py` is the LZMACompressor and LZMADecompressor objects,
  the constants and LZMAError that CPython's own `lzma.py` is written against.
  A filter chain crosses the boundary as a list of TUPLES OF INTS rather than
  as the dicts a caller writes: the option names, the defaults and the
  per-filter error wordings are Python's business, the struct layout is the
  assembly's
- `src/modules/ctypes.asm` — the `_ctypescore` module: dlopen/dlsym, reading
  and writing memory at an address, libffi's `prep_cif` and `call`, and one
  closure trampoline every CFUNCTYPE callback enters through (it calls back
  into Python the way `pyexpat_cb.asm` does).  A shim over `-lffi`, and its
  arguments ARE raw addresses: that is ctypes.  `lib/_ctypes.py` is the whole
  object model CPython's unmodified `Lib/ctypes` is written against -- the
  metatypes, layout and bitfields, the `_objects` keep-alive tree, argument
  conversion, callbacks -- with each instance's memory a bytearray it owns or
  an address it borrows.  `tests/ctypes/` is CPython's `_ctypes_test.c` over a
  stand-in `Python.h`, built to `build/_ctypes_test.so` for CPython's ctypes
  tests, which only ever reach it through `CDLL(_ctypes_test.__file__)`
- `src/modules/hashlib.asm` — the `_hashlibcore` module: OpenSSL's
  EVP_MD_CTX and HMAC_CTX, PBKDF2, scrypt and a constant-time compare, behind
  a handle table.  A shim over `-lcrypto`, the same split again:
  `lib/_hashlib.py` is the HASH, HASHXOF and HMAC objects and the
  `openssl_<name>` constructors CPython's `hashlib.py` and `hmac.py` are
  written against.  What it buys over `lib/_sha2.py` and its siblings is
  `pbkdf2_hmac` and `scrypt`, which have no honest Python form at the
  iteration counts anyone uses, and the speed to hash gigabytes.
  CPython's own `hashlib.py` decides the routing: OpenSSL for twelve of the
  fourteen, and `lib/_blake2.py` for blake2b and blake2s always, because
  OpenSSL's BLAKE2 supports neither keying nor the tree parameters
- `src/modules/ssl.asm` — the `_sslcore` module: libssl behind a handle
  table, the same split again with `lib/_ssl.py` as the `_ssl` surface
  CPython's `ssl.py` imports (`_SSLContext`, `_SSLSocket`, `MemoryBIO`,
  `SSLSession`, `Certificate`, the exception family and the constants).
  What is peculiar to libssl is its width, so the core is not a wrapper per
  call: each OpenSSL function is one `SSLFN` row -- symbol, result letter,
  argument letters -- and one engine, `ssl_call`, converts and calls.  The
  letters are documented at the top of the file; adding a call is adding a
  row.  OpenSSL never calls Python: a password is evaluated first and parked,
  an SNI callback runs while the client-hello callback holds the handshake
  paused, keylog lines are queued and drained, and a certificate is decoded
  from its DER by the ASN.1 reader at the bottom of `lib/_ssl.py`
- `src/modules/socket.asm` — the `_socketcore` module: the socket syscalls and the
  constant table, taking and returning sockaddrs as opaque bytes.  The socket
  type, the address packing and `select` are `lib/_socket.py` and
  `lib/select.py`, the same split as `_iocore`/`lib/_io.py`
- `src/pyo/asyncmod.asm` — the `_asynciocore` module: the task type, the
  event loop, `run`, `sleep`, `gather`, `wait_for`, `create_task`, and
  `wait_fd`.  Nothing reaches it any more: `asyncio` is CPython's package,
  over `selectors`, since the standard library became CPython's own.  It is
  kept for a fast event loop to offer through the loop-policy API later, and
  is otherwise dead weight
- `src/itertools.asm` — the *iterator builtins* (`enumerate`, `zip`, `map`,
  `filter`, `reversed`, `sorted`, `chain`, `get_iterator`), not the `itertools`
  module, which is `lib/itertools.py`
- `src/dunder.asm` — dunder lookup and the `dunder_call_*` helpers, the
  fallback path when a heaptype has no slot
- `src/repr.asm` — the container reprs and the recursion stack they share
- `src/gc.asm` — the generational collector.  Each type's `tp_traverse` and
  `tp_clear` live with the type, in `src/pyo/*.asm`
- `src/sre.asm` / `src/sre_char.asm` / `src/modules/sre.asm` — the regex
  engine, its character layer (code-point fetch, the categories, character
  sets, the position assertions and case folding) and its module wrapper;
  the pattern and match objects live in `src/pyo/`
- `src/valtest.asm` — `--selftest-value`
- `src/alloctest.asm` — `--selftest-alloc`: the pool allocator hammered
  directly, with no objects and no eval loop.  An allocator bug reaches
  Python as data corruption in code that is correct, so it is caught here
- `src/builtins.asm` — `PyBuiltinObject`, the core builtins, and `builtins_init`
- `src/builtins_num.asm` / `src/builtins_obj.asm` / `src/builtins_str.asm` —
  the numeric builtins, the object/iteration/IO builtins, and `str()` with the
  three-argument decode form; `src/builtins_pow.asm` is `pow()` and the
  modular exponentiation GMP does for its three-argument form
- `src/builtins_type.asm` — `isinstance()` and `issubclass()`, and
  `obj_declared_class`, the "what does this object say it is" step they share.
  CPython asks the real type first and `__class__` only when that says no, and
  so does this
- `src/buildclass.asm` — `type.__new__`, `type_from_parts`, `__build_class__`
- `src/slots.asm` — Installs slot wrappers on a heaptype from the dunders it defines
- `src/mro.asm` — C3 linearization, `type_mro_next`, `type_is_subtype`
- `src/format.asm` — The format-spec mini-language (`format()`, f-strings, `%`)
- `src/traceback.asm` — Both code-object side tables: PEP 626 line table and
  `co_exceptiontable`, plus traceback rendering
- `src/frame.asm` — Frame alloc/dealloc
- `src/object.asm` — Base PyObject ops (alloc, refcount, dealloc, `obj_richcompare_bool`)
- `src/objerr.asm` — the arity and receiver error messages, split off when
  `object.asm` reached the 100k cap.  Each builds its text into a stack
  buffer and hands it to `raise_exception`; none of them returns
- `src/runtime.asm` — The freestanding layer: syscalls, PLT-free memory and
  string ops, and `fatal_error`
- `src/alloc.asm` — where memory comes from.  `ap_malloc`, `ap_free` and
  `ap_realloc` are the whole funnel: nothing else in the tree calls libc's,
  and GMP and zlib allocate and free their own, so every byte the interpreter
  owns passes through these three.  They are a size-class pool allocator over
  one contiguous reservation, with libc under it above 512 bytes; the file
  header is the design, including the three invariants it rests on.
  `NO_POOL=1` compiles it out and `APYTHON_MALLOC=libc` switches it off
  without a rebuild -- **use the latter under valgrind**, or every
  use-after-free goes invisible.  `POOL_TINY=1` shrinks the reservation so the
  whole corpus runs on a mixed pool/libc heap
- `src/compiler/` — The Python **source** compiler (see below)
- `src/include/` — `object.inc` (every struct and id enum), `macros.inc`,
  `value.inc`, `threadstate.inc` (the per-thread state, see above), `opcodes.inc`, and the three private ABIs `sre.inc`,
  `eventloop.inc` and `listsort.inc`

## Source Compiler (`src/compiler/`)

Turns Python 3.12 source into a `PyCodeObject` this interpreter runs.  Reached
through `compile()`, `exec()`, `eval()`, `./apython foo.py`, and `import` of a
`.py` when no `.pyc` is there.  The whole language: `match`, `except*`,
f-strings, async, comprehensions, PEP 695 type parameters.

| file | role |
|------|------|
| `compiler.inc` | token kinds, AST kinds, binding powers, `Buf`/`Comp`/`CompUnit`/`Instr` |
| `tables.asm` | **generated** — char classes, keywords, operators, opcode metadata |
| `gen_tables.py` | regenerates `tables.asm` from CPython 3.12's `opcode`/`dis` |
| `gen_prule.py` | regenerates `prule.asm`, the expression grammar table |
| `lex.asm` | tokenizer: indentation, operators, names, numbers, strings |
| `ast.asm` | 32-byte nodes in a `Buf`, addressed by u32 index, and the growable `Buf` / bump `Arena` they live in |
| `parse.asm` | Pratt expression parser and its prefix/infix handlers |
| `parse_str.asm` | string literals: the escapes, `\N{...}`, implicit concatenation, and whether a run is an f-string |
| `prule.asm` | **generated** -- `prule_table`, the precedence grammar |
| `parse_stmt.asm` | statements, and the soft keywords `match` and `type` |
| `parse_try.asm` | `try` and `with`, which share a frame layout because they are the same shape -- a suite, then clauses that run whether it finished or not.  Split off when `parse_stmt.asm` reached the 100k cap, along the seam `codegen_try.asm` already uses |
| `pattern.asm` | `match` patterns |
| `fstring.asm` | f-string fields, lexed as spans of the same source |
| `fstrscan.asm` | where a literal ends, under PEP 701 -- the one definition the lexer and both field scanners share |
| `symtab.asm` | scopes, local/cell/free classification, name mangling |
| `codegen.asm` | AST kind → emitter jump table; `_stmt`/`_func`/`_try`/`_comp`/`_match` for the rest.  `_try` also holds `except*`, `with` and `await`: they are one unwinder |
| `assemble.asm` | EXTENDED_ARG fixpoint, stack depth, exception table, line table |
| `compile.asm` | pipeline driver and lifetime, and the `code_from_path` and `compile()`/`exec()`/`eval()` entry points |
| `comperr.asm` | how a compile REPORTS rather than what it compiles: `comp_error` and its siblings (the compiler cannot raise, so an error is recorded and made pending after every buffer is freed), the message builder, the location a SyntaxError carries, and the deferred warnings.  Split off when `compile.asm` reached the 100k cap |
| `unicodename.asm` | **generated** -- the names `\N{...}` resolves, front-coded: `db shared, cpdelta, "suffix", 0` per entry, decoded as the scan walks |
| `gen_unicodename.py` | regenerates `unicodename.asm` from `unicodedata` |
| `unicodecase.asm` | **generated** -- the case mappings and the character flags |
| `gen_unicodecase.py` | regenerates `unicodecase.asm` from CPython's own `str` methods |
| `gen_unicodenorm.py` | regenerates `src/modules/unicodenorm_tables.asm` -- the decompositions, the combining classes and the pairs that recompose, which is what `unicodedata.normalize` needs |
| `gen_ucd32.py` | regenerates `src/modules/ucd32_tables.asm` -- the same tables plus the run properties, at the Unicode 3.2 RFC 3454 froze, which is `unicodedata.ucd_3_2_0` |
| `uniname.asm` | the search over it, plus the algorithmic CJK family |
| `dis.asm` | `--dis`, for diffing against `python3 -m dis` |
| `comptest.asm` | `--selftest-compile` |
| `lint.py` | static checks, run by `make check` |

**Never call `raise_exception` from `src/compiler/`.** It tail-jumps into
`eval_exception_unwind`, which calls `fatal_error` when there is no live
interpreter frame — and `./apython foo.py` compiles before any frame exists.
Record the error with `comp_error()` and return 0/NULL; the driver turns it
into a pending exception after every buffer is freed.

`op_meta` in `tables.asm` is the keystone: one row per opcode drives CACHE
padding, instruction sizing, stack-depth accounting and successor computation.
Because every emission routes through it, a forgotten CACHE is not a mistake an
emitter can make. Its numbers are CPython's, taken from the running
interpreter's own modules rather than transcribed.

Regenerate all four with `make regen`.  The outputs are committed, so building
never needs Python -- and `gen_tables.py` refuses to run on anything but CPython
3.12, so they must not become build steps.  `make clean` leaves them alone.

**Gates:** `make check-source` and `make check-cpython-source` (both corpora
compiled by this compiler and diffed against `python3` — where nearly every bug
below was found), `tests/syntax_probe.sh` (every field of a SyntaxError, over
`tests/syntax_corpus.txt`, against CPython's; `--show` prints what differs),
`./apython --selftest-compile`, `python3 src/compiler/lint.py`,
and the `tests/test_compile_*.py` files.  All but the two `-source` targets run
inside `make check`.

### Compiler bug patterns

These cost real time; the shapes recur.

- **A binding power that is equal where it should be one below.** The Pratt
  driver continues while `lbp > min_bp`, so an operand parsed AT an operator's
  own power stops before it.  A ternary's else branch at `BP_TERNARY` nests
  left, a lambda body at `BP_TERNARY` loses its own `if`.  Both produce wrong
  answers, not errors.
- **Two index spaces that collide.** Object indices and node indices come from
  different arenas and overlap freely.  `sym_visit`'s generic walk follows a
  node's `a`/`b`/`c`, and any kind whose fields are *object* indices has to be
  on the exclusion list — `AST_HANDLER` was not, so `except E as e` visited
  whatever node sat at e's object index.  Nothing smaller than a whole file
  brings the two into range.
- **A stack effect read from the interpreter rather than from CPython.**
  `MATCH_KEYS` consumes neither the subject nor the keys tuple; a depth taken
  from what the handler *looks* like it does is silently one out, and the
  damage surfaces somewhere else.
- **A jump to a label that was never bound.** It held -1, which the resolver
  read as an unsigned offset past the end of the stream.  `asm_check_labels`
  now rejects it; before that it was a jump off the end.
- **A return value clobbered by the epilogue.** `cg_class_value` restored the
  enclosing scope through `eax` on its way out, so every failure was reported
  as a success and the caller emitted code for something that was never built.
- **A function emitted while a data section is current.** NASM allows it and it
  links; the fault arrives when the CPU refuses to execute the page, as a
  SIGSEGV on the function's own `push rbp`.  `lint.py` checks for it.
- **A callee-saved register used without saving it.** `main` keeps argc and
  argv in r14 and r15 across the compile, so a scratch r14 in an emitter hands
  back a different argv and the crash lands in `sys.argv` construction.
  `lint.py` checks both directions.

## Key Structs

Defined in `src/include/*.inc`. All objects start with `PyObject` (ob_refcnt +0, ob_type +8).

- **PyTypeObject** (object.inc): tp_call +64, tp_getattr +72, tp_setattr +80, tp_as_number +128, tp_as_sequence +136, tp_as_mapping +144, tp_base +152, tp_mro +168, tp_bases +184, tp_dictoffset +208
- **PyFrame** (object.inc): code +8, globals +16, locals +32, stack_ptr +48, stack_base +56, disp_ip +80, disp_sp +120 (both written by DISPATCH), localsplus +128 (variable-size Value[])
- **PyIntObject** (object.inc): mpz +16 (only initialised on overflow), ival +32, compact +40 (1 = the ival is live)
- **DictEntry** (object.inc, 24 bytes): hash +0, key +8, value +16 — occupied ⇔ `key != 0`; empty ⇔ `key == 0 && hash == 0`; tombstone ⇔ `key == 0 && hash == -1`
- **PyCodeObject** (object.inc): co_consts, co_names, co_firstlineno +112, co_linetable +120, co_code starts at +128
- **PyStrObject** (object.inc): ob_size +16 is the length in **bytes**, ob_length +32 the length in **code points**, data +40 is NUL-terminated UTF-8.  They are equal for ASCII, which is the fast path every code-point-aware operation checks first.  A new string must set both: `str_set_length` counts, or compute it directly when the arithmetic is obvious.  `str_cp_offset` and `str_byte_to_cp` convert between the two index spaces
- **PyWeakRefObject** (object.inc): wr_object +16 is a *borrowed* referent, zeroed when it dies.  The links live in a side table in `src/pyo/weakrefmod.asm`, consulted by `obj_dealloc` only when `weakref_live` is non-zero

## Opcode Handler Pattern

```nasm
op_example:
    ; ecx = arg (already set by eval_dispatch)
    ; rbx already advanced past 2-byte instruction word
    ; ... implementation ...
    DISPATCH          ; jmp eval_dispatch
```

Stack macros: `VPUSH reg` (an encoded Value), `VPUSH_PTR reg`, `VPUSH_INT reg, scratch`, `VPUSH_FLOAT reg, scratch`, `VPUSH_NONE`, `VPUSH_BOOL reg`, `VPUSH_NULL`, `VPOP reg`, `VPEEK reg`.  `VPUSH_VAL` / `VPOP_VAL` are the (payload, tag) shims.

## Named Frame-Layout Constants

**Never use raw numeric offsets** like `[rbp-8]`, `[rbp-16]`, `[rsp+32]` in handler code. Instead, define named `equ` constants at the top of the file and reference them as `[rbp - SA_OBJ]`, `[rsp + BO_LEFT]`, etc.

```nasm
; At top of file, after externs:
SA_OBJ    equ 8
SA_VAL    equ 16
SA_NAME   equ 24
SA_FRAME  equ 24

; In handler:
DEF_FUNC op_store_attr, SA_FRAME
    mov [rbp - SA_OBJ], rdi
    mov rsi, [rbp - SA_NAME]
```

Convention: 2-3 letter handler prefix + field name (e.g., `SA_OBJ`, `CL_NARGS`, `LA_ATTR`). Use `XX_FRAME equ N` for the `DEF_FUNC` frame size argument. For push-based layouts, use offsets relative to `rsp`.

## Python 3.12 CACHE Entries

Opcodes have trailing CACHE words that must be skipped. Key counts (each = 2 bytes):

| Opcode | CACHE entries | Skip bytes |
|--------|--------------|------------|
| LOAD_ATTR | 9 | 18 |
| STORE_ATTR | 4 | 8 |
| CALL | 3 | 6 |
| BINARY_OP | 1 | 2 |
| COMPARE_OP | 1 | 2 |

## Known Bug Patterns

- **Marshal FLAG_REF ordering:** Container types must reserve ref slot BEFORE reading children (r_ref_reserve/r_ref_insert pattern). See marshal.asm.
- **func_call r12 assumption:** func_call assumes r12 = caller's frame. When called from type_call (which overwrites r12), must restore r12 from stack.
- **DECREF clobber:** DECREF_REG contains `call obj_dealloc`. Any value in caller-saved regs is destroyed if refcount hits zero.
- **Double encode/decode:** a function that packs at its exit must not be reached by a tail `jmp` from another that also packs, and a call site must not decode a result its callee already handed over as a Value. Both show up as a value off by exactly 2^48 (floats) or by V_INT_BIAS (ints), not as a crash.
- **Raw payload use after conversion:** once a slot holds a Value, reading it and using it as an int or as raw double bits needs `V_TO_I64` / `V_TO_F64` first. Pointers are the exception — a pointer is its own Value — which is why pointer-only code survived the conversion untouched and non-pointer code did not.
- **Shadowing a builtin base's slot:** a dunder that `object` itself supplies is not a definition.  `type_install_slots` skips them (`slot_is_object_default`), or a tuple subclass would compare by identity instead of by contents.  The same technique keeps `instance_repr`/`instance_str` from picking up `object.__repr__` ahead of a builtin base's
- **Boxing in V_PACK:** `V_PACK` on a TAG_SMALLINT outside ±2^50 allocates a heap int. That is correct but it is an allocation, and the returned reference is owned — do not pack a borrowed integer payload and drop it.
- **Two exception globals, and they answer different questions.** `current_exception` is the one *in flight*; `handled_exception` is the one an `except` block is *handling*, which `PUSH_EXC_INFO` installs and `POP_EXCEPT` takes down. `sys.exc_info()`, a bare `raise` and an implicit `__context__` all read the second. `eval_frame`/`eval_return` swap `handled_exception` with `PyFrame.exc_state` around every frame, so a frame handling nothing shares its caller's and a suspended generator carries its own. Snapshotting `current_exception` before a call (`DUNDER_EXC_SAVE` / `DUNDER_RAISED` / `EXC_RAISED_SINCE`) is still the right way to ask "did that raise?", because `call_iternext` legitimately clears a StopIteration.
- **Following `tp_base` to resolve an attribute or answer a subclass question.** With multiple inheritance the answer lives on the MRO: use `MRO_NEXT walker, origin` (or `type_is_subtype`), keeping the type the search *started from* as the origin. A static type has no `tp_mro`, and for it `MRO_NEXT` still yields `tp_base`, so single-inheritance code reads the same.
- **Writing through an inherited method table.** `type_from_parts` gives a builtin subclass its base's `tp_as_number` / `tp_as_sequence` / `tp_as_mapping` *pointer*. Writing a slot through it patches the builtin's own static table for the whole process; `slot_ensure_table` copies first. The same shape applies to anything else inherited by pointer.
- **A 64-bit read of a 4-byte struct field.** `mov rdx, [rsi + Token.len]`
  assembles fine and silently ORs in the next field as the high half; here it
  produced a multi-gigabyte `ap_memcpy`. Use the 32-bit form (`mov edx`), which
  zero-extends. `src/compiler/lint.py` checks this.
- **A call made with `rsp` misaligned.** After `DEF_FUNC`'s `push rbp`, a
  `sub rsp, N` and P register pushes, the SysV ABI wants `(N + 8*P) % 16 == 0`.
  The compiler calls `strtod` and the numeric builtins reach GMP, and glibc's
  float paths do use aligned SSE. `src/compiler/lint.py` checks it tree-wide;
  pad the frame rather than the push list. A prologue that carves its own
  space after the pushes is the exception: growing its `DEF_FUNC` frame moves
  `rsp` without moving the buffer it addresses off `rbp`, so change the
  `sub rsp` and every matching `add rsp` together instead.
- **A frame slot overlapping a struct in the same frame.** A hand-picked
  `equ` for a large struct silently overlaps the scalar slots above it the
  first time the struct grows, and the symptom is one field reading as garbage.
  Derive the offset instead: `CS_UNIT equ 48 + CompUnit_size`.
- **Following a node's `a`/`b`/`c` without asking what kind it is.** The node and object arenas overlap freely, so a generic walk that visits a field holding an *object* index lands on an unrelated node. `sym_visit` keeps an exclusion list; `cg_has_annotation` recurses only into the compound statements whose fields really are blocks. A `for/else` is the other half of the same trap: it hides its else block in `clist` with `nchild` at 0, where no child-list walk reaches it.
- **Leaving a block early must emit its cleanup outside that block's own region.** The exception table is built from a per-instruction handler stamp, so the `__exit__` a `return` emits carries whatever stamp is current — the with's own, unless the unwinder sets it to the enclosing one first. Each entry on the block stack records that enclosing handler for exactly this. A `return` also leaves every enclosing *loop*, whose iterator is on the stack under the return value.
- **A borrowed pointer in `CompUnit.names` or `.consts`.** Both hold borrowed references; the object arena owns them. A string interned at the call site and released leaves a dangling pointer whose symptom is a wild jump inside `dict_lookup` at run time, and a code object never handed to the arena is simply never freed. `comp_intern_cstr` and `comp_intern_keep` are the way in.
- **A variable-size builtin whose subclass gets a fixed-offset `__dict__` or `__slots__`.** str and bytes keep their data inline, so a dict at the base's `tp_basicsize` lands *inside* it. They get `TP_DICT_AT_TAIL`; bytearray and memoryview, which can move or borrow their storage, get none at all — but still need `tp_basicsize` set, or the dealloc slot walk reads a negative count. A str subclass's `__slots__` go at the tail for the same reason, counted by `tp_tailslots` and addressed by a NEGATIVE `md_offset`; int, bytes and tuple subclasses refuse slots outright, as CPython's do.
- **Asking "is this object a class?" by comparing metatypes.** `ob_type is user_type_metatype` is false for a class built by a metaclass of its own, so a classmethod reached through such a class bound the *metaclass*. Test `TYPE_FLAG_METATYPE` on the object's type instead; it is set on `type`, on the two metatypes we ship, and on any class deriving from `type`.
- **An empty `bases` tuple is not the same as no bases.** `type(n, (), d)` substituted `object`; the metaclass paths did not, and those classes got an MRO of just `[C]` — not even instances of `object`. Invisible until a merge needs the `object` that anchors the end.
- **A builtin's behaviour that lives only in a slot.** The stdlib asks questions by name: `hasattr(f, '__get__')` decides whether something is a descriptor, `member_type.__str__ is object.__str__` decides whether a type defines its own `str()`. A slot with no matching entry in `tp_dict` answers those wrong. When adding one, the thunk must call the *defining* type's slot, not the argument's, or a subclass re-dispatches into itself.
- **A constructor in `tp_call` rather than `tp_new`.** `tp_call` on a type is what makes that type's *instances* callable; the constructor goes in `tp_new`, which `type_call` consults. `mappingproxy` had neither, so calling it fell through to the ordinary class-construction path and left its fields holding whatever was there.
- **Reading a key's tag out of `edx` in an `mp_subscript`.** `BINARY_SUBSCR` builds the key Value with `V_PACK`, which *clobbers* the register the tag was in — the value left behind happens to equal `TAG_SMALLINT` for positive ints and not for negative ones. Classify from the Value itself with `V_TEST_PTR`.
- **A constant that is a Value, not a pointer.** `ast_obj_at` hands back whatever the object arena holds, and `class C: 42` puts an immediate int there. Reading `ob_type` off one dereferences the number.
- **A heaptype whose `tp_basicsize` was patched to make room for C-level
  fields.**  `instance_dealloc` and `instance_traverse` both walk every word
  from the dict slot to `tp_basicsize` and treat it as a `__slots__` Value --
  one DECREF_VALs it, the other hands it to the collector.  A file descriptor
  of 3 read as a Value is a pointer to address 3.  `_io.FileIO` and
  `_io.BytesIO` give the type its own `tp_traverse` and `tp_clear`, and their
  dealloc zeroes the raw fields before delegating.  A subclass of such a type
  cannot declare `__slots__`: they would land in the same words.

- **An argument that is an index, taken with `int_to_i64`.** It reads
  `PyIntObject.compact` off whatever it is handed, so `"a\tb".expandtabs("x")`
  read a str's header as a number. `obj_as_index` is the funnel: it names the
  type and it takes anything with `__index__`. A slice bound wants
  `obj_as_slice_index`, which is the same test and CPython's other wording.
  A truth value -- `splitlines(keepends)` -- is neither, and wants
  `obj_is_true`.

- **A builtin `__next__` that raises StopIteration with `RAISE`.**  `RAISE`
  tail-jumps into the unwinder, and a builtin has no Python frame of its own
  to stop at, so the StopIteration unwinds straight past `slot_tp_iternext`
  and out of the `for` that was calling it.  Use `SET_EXC` and return NULL;
  the slot wrapper is what turns StopIteration into exhaustion.

- **Turning on `TYPE_FLAG_HAVE_GC` without moving every allocation site.**
  The flag is what `gc_dealloc` reads to decide whether to free at
  `obj - GC_HEAD_SIZE`, so the moment a type carries it, EVERY place that
  builds one of its instances has to come from `gc_alloc` and every free has to
  go through `gc_dealloc`.  A second constructor still using `ap_malloc` hands
  the allocator a pointer sixteen bytes short of what it gave out, and the heap
  corruption surfaces as segfaults in unrelated tests.  `frame_object_type` had
  two constructors -- one for `sys._getframe()`, one for a traceback's snapshot
  -- and only the first was moved.  A type declaring `tp_traverse` and
  `tp_clear` while its instances are never tracked is the other half of the
  same mistake: the collector never sees them, so a cycle through one is
  uncollectable.

- **A removed load whose guard stayed.** The `(payload, tag)` conversion deleted many `key_tag` loads; where the `test`/`jz` that used them was left in place it now reads a stale register — `from mod import *` and `dict.popitem()` both failed this way, silently. When deleting a load, delete its test.
  **And keep reading past the test.** The guard is rarely the only consumer:
  converting `dunder_lookup`, `dunder_call_1` and `dict_get` to return a Value
  swept every guard and left five `V_PACK rax, rdx` / `INCREF_VAL rax, rdx`
  one line below one, still reading the tag register nothing had written. All
  five produced wrong ANSWERS rather than crashes — an int 2^50 out, or an
  INCREF skipped and a borrowed reference pushed — so `make check`,
  `check-cpython`, both `-source` gates, `lint.py` and `INT_STRESS=1` were all
  green over them. After converting a funnel, grep its call sites for the tag
  register and read to the next write of it, not to the next branch.

## Adding a New Test

Create `tests/test_feature.py` using only implemented Python features. `make check` auto-discovers `test_*.py` files.

## Debug Strategy

Build includes DWARF symbols (`-g -F dwarf`) and ELF function metadata (STT_FUNC type + size via `DEF_FUNC`/`END_FUNC` macros). All functions use RBP frame pointers, enabling GDB frame-pointer-based unwinding. Zero runtime overhead.

**What works in GDB:**
- `bt` — full backtraces via RBP chain
- `break func_name` — breakpoints on any global function
- `info functions` — lists all functions with correct boundaries
- `disassemble func_name` — disassembly with proper function bounds
- `step`/`next`/`finish` — source-level stepping (maps to .asm lines)
- `info registers` — inspect VM state (rbx=bytecode IP, r12=frame, r13=stack top, r14=consts, r15=names)

**GDB quick start:**
```
gdb ./apython
break eval_frame
run tests/__pycache__/test_foo.cpython-312.pyc
bt                    # backtrace
info registers        # VM state: rbx, r12-r15
print (char*)[r12+8]  # inspect frame->code
break str_from_cstr   # break on runtime function
continue
```

**VM register inspection in GDB:**

| Expression | Meaning |
|------------|---------|
| `$rbx` | Current bytecode IP |
| `$r12` | Current PyFrame* |
| `$r13` | Value stack top |
| `$r14` | co_consts data ptr |
| `$r15` | co_names data ptr |

**Function definition macros** (src/include/macros.inc):
- `DEF_FUNC name` — global function with RBP frame (push rbp + mov rbp,rsp)
- `DEF_FUNC name, N` — same + allocate N bytes of local space
- `DEF_FUNC_BARE name` — global function, no prologue (opcode handlers, leaf functions)
- `DEF_FUNC_LOCAL name` — file-local function with RBP frame
- `END_FUNC name` — marks function end (required, emits .end label for ELF size)

Write debug scripts to `/tmp/` and run with `bash /tmp/script.sh`.
