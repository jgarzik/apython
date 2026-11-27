# Roadmap

What stands between this tree and its mission, in the order to close it.

**Mission.** A complete Python 3.12 for Linux x86-64, written in assembly,
judged against CPython itself: **95% or more of the tests CPython 3.12 passes**,
no crashes on CPython's corpora, and performance at or above CPython's.

This file owns "what is left and in what order".  It replaces `bugs.md`, whose
open entries are in the [defect list](#open-defects) below.  `DIVERGENCES.md`
records where the tree answers differently from CPython and why; nothing in it
is a ruling, and the entries that cost tests are scheduled here like any other
gap.

Every number below was measured on 2026-11-27 at `a5ef4923`, against a
CPython 3.12.9 built from `~/tmp/repo/cpython`.  They are a snapshot for
ranking, not a ledger: re-measure at each phase gate.

## Where we are

The latest matched CPython 3.12.9 run reports **30,129 of 42,074** passing
test IDs in mission scope (71.61%) and **30,178 of 43,097** against the
full measured denominator (70.02%). apython completed the sweep without
a process crash or timeout. The CPython control timed out in `test_runpy`
and aborted in `test_tracemalloc`.

The package, source, curated CPython-source and stdlib gates pass. The
aggregate macro benchmark measured 1.41x CPython and the core suite 1.52x.

### Earlier aggregate snapshot

| Gate | Result |
|---|---|
| `make check` | green |
| `make check-cpython` | green |
| `make check-source` | green; floor not raised for the newest test files |
| `make check-cpython-source` | green |
| `make check-stdlib` | green |
| `make check-pkg` | **red**: `test_capi`, `test_cext`, `test_cppext`, `test_inspect` below their floors; thirteen directories above theirs and unrecorded |
| lint, the three selftests | green |
| stdlib modules that import | 545 of the 592 CPython imports on this machine |

The measurement the mission is judged by, both halves of `Lib/test`:

| Corpus | CPython passes | apython passes | Headline | Strict |
|---|---|---|---|---|
| `test_*.py` files (`tests/rc_sweep.sh`) | 31,996 | 27,854 | 87.1% | 82% |
| `test_*/` packages (`-m unittest test.<pkg>`) | 12,524 | 9,326 | 74.5% | 66% |
| **Both** | **44,520** | **37,180** | **83.5%** | **77%** |

*Headline* counts a test as passing when it ran and did not fail.  *Strict*
also subtracts the tests apython **skipped** and CPython ran: about 1,750 in
the files and 1,080 in the packages.  A skip is a missing feature that the
test suite was polite about, and the headline has been overstating progress by
six points because of it.  **Strict is the number to steer by.**  Reaching 95%
strict means closing roughly 8,000 of the 10,300 tests now failing or skipped.

One crash (`test_yield_from`, SIGSEGV), one core dump (`test_resource`), one
fatal out-of-memory (`test_fstring`, intermittent), two hangs
(`test_cmd_line_script`, `test_zipfile64`).  Each was re-run by hand against
the same binary.  Of the 367 file modules where CPython passes anything,
101 are at full parity; 156 are within ten tests of it.

Performance: macro suite 1.34x CPython, core 1.40x, int 1.78x, float 2.06x,
list 1.33x, str 1.11x, dict 1.05x, set 1.02x.  The suites are above 1.00x in
aggregate and carry individual rows well below it (listed under
[performance](#performance)).

### How to re-measure

```bash
RC_OUTDIR=<dir> bash tests/rc_sweep.sh ap      # then: cp
bash tests/pkg_probe.sh                        # apython side of the packages
```

Run `make conformance` for a matched file and package report by test ID.
The control binary and its source checkout must match the vendored CPython
release. For focused runs, pass module names to `python3 tests/conformance.py`.
Use `--output` to keep logs and per-test outcomes. A crash, timeout, or
incomplete control is visible on its module row; the published score covers
completed control runs.

The older scripts still provide the aggregate snapshot above and the package
floor. Their aggregate counting is different from the matched-ID report.

The control is itself imperfect: under it `test_runpy` hangs,
`test_tracemalloc` aborts and `test_monitoring` reports no tests, so those
modules contribute nothing to the denominator.

## Decisions that set the target

About 2,400 of the failing tests exercise CPython's *implementation* rather
than Python.  Whether they count decides how far 95% is.

| Group | Tests | What they need |
|---|---|---|
| `@cpython_only`, skipped because `sys.implementation.name` is `apython` | ~510 | Mixed.  `test_traceback` (122), `test_sys_settrace` (74), `test_call` (47), `test_sys` (21) are mostly ordinary behaviour behind the decorator; the rest assert refcounts and C layout |
| The C API: `test_capi`, `_testcapi` users (`test_call`, `test_dict_version`, `test_embed`, `test_fileutils`), `_testclinic`, `_testbuffer`'s `ndarray`, `test_cext`, `test_cppext` | ~1,400 | A C extension ABI.  Out of scope for the chosen endpoint |
| Subinterpreters: `test_interpreters`, `test__xxsubinterpreters`, `test__xxinterpchannels` | ~210 | A second interpreter state in one process |
| `test_gdb`, `test_perf_profiler`, `test_asdl_parser` | ~70 | A CPython source build |

The mission score excludes named C API, subinterpreter, source-build and
implementation-layout tests. The full-denominator score is reported alongside
it. `tests/conformance_scope.txt` records the current audit and opts individual
behavioural definitions guarded by `cpython_only` into the matched run.

Measured, by running those tests with the implementation name patched to
`cpython`: of about 490, **116 already pass**, 311 fail and the rest do not
run.  114 of the failures are `test_traceback` wanting one function,
`_testcapi.exception_print`; and un-skipping `test_call` exposes a segfault
in `test_super_deep` (deep recursion overruns the C stack).
With that denominator the strict figure today is about 80%, and 95% is about
6,400 tests away.

## The sequence

Ordered by tests unlocked per unit of work.  Counts are strict (failures plus
excess skips) and overlap a little between rows.  Each phase ends with the
full gate set, both sweeps and the benchmarks.

### Phase 0 -- Make the instrument honest

- The matched report counts shared passing test IDs and ranks skip reasons.
  The scope file records the exclusions and selectively re-enables
  behavioural cases behind `cpython_only`.
- The package and source floors record the verified gains. Returning code
  position iterators restored the `test_inspect` floor. The excluded C API
  packages still run and count toward the crash check.
- `test_yield_from` completes after guarding a delegating generator during
  `throw()` and `close()`. `test_resource` passes after ignoring SIGXFSZ
  at startup. Deep Python recursion now raises on both the main stack and
  a worker stack.
- `test_cmd_line_script` completes and passes its four stream-flush cases.
  `test_zipfile64` passed all four tests with a 300-second budget. An
  isolated apython run took 126 seconds.
- The intermittent quiet-run `test_fstring` OOM remains open. It occurred
  under the sweep's address-space limit. Subsequent quiet runs completed
  with 53 of the 85 control passes.

### Phase 1 -- Whole modules behind one missing piece

Each item is a single absent name or module with hundreds of tests behind it.

| Item | Tests | Work |
|---|---|---|
| `array._array_reconstructor`, and `array.__reduce_ex__` to match | 814 | `test_array` dies at import on the one name.  Pickling an `array` fails today too |
| `_multiprocessing` (`SemLock`), `_posixshmem`, fd passing over `sendmsg` | ~1,500 | Unlocks the three `test_multiprocessing_*` packages, `test_concurrent_futures` (255), `ProcessPoolExecutor`, `test_multiprocessing_main_handling`, `compileall -j` |
| `_asyncio` | ~900 | Build native loop and task bookkeeping, `Future`, and `Task` before enabling the accelerator. Then close the asyncio failures in text-mode `makefile`, pidfd watchers, and `sendmsg`. |
| `_sqlite3` | 468 | A shim over `-lsqlite3`, in the shape `zlib.asm`/`lib/zlib.py` set.  Callbacks from C into Python follow `pyexpat_cb.asm` |
| `_gdbm`, `_dbm` | ~230 | Shims over libgdbm.  `test_shelve` silently runs half its classes without them; `test_dbm`, `test_dbm_gnu`, `test_dbm_ndbm` |
| C-accelerator stand-ins: `_functools` (96), `_uuid` (37), `_queue` (28), `_heapq` (25), `_bisect` (22), `_statistics` (20), `_elementtree` (19), `_stat` (6), `_opcode` (3), `_json`'s five names (12) | ~270 | Mostly re-exports under the C name.  `_json`, `_bisect` and `_stat` are imported as `None` by fresh-module tests today and take the test class with them |
| `_curses`, `_curses_panel` | 79 | Shim over ncurses |
| `_symtable` | 27 | The compiler already builds the table; expose it |
| `_locale` | ~40 | `setlocale`, `localeconv`, `nl_langinfo` and the `LC_*`/`langinfo` constants over libc |
| `_crypt`, `spwd` | ~10 | libc `crypt`; `/etc/shadow` reader |
| `_tracemalloc` | (control aborts) | Hook `ap_malloc`; also what `-X tracemalloc` and `ResourceWarning`'s hint want |

### Phase 2 -- The platform surface

`posix` and `_socket` are subsets, and the test suite skips rather than fails
on what is missing, so none of this shows in the headline.

- **Name resolution does not work.** `socket.getaddrinfo("www.python.org",
  80)` and `gethostbyname` raise `gaierror: Name or service not known`; only
  names that need no DNS resolve.  No test counts this -- the network tests
  skip -- but nothing that talks to the internet by name can run, `pip
  install` and `urllib` included.  This is the largest gap the test suite
  does not measure, and it goes first in this phase.
- **Sockets, ~480.** `sendmsg` / `recvmsg` / `recvmsg_into` and `CMSG_LEN` /
  `CMSG_SPACE` (345 skips on their own); IPv6 (`has_ipv6` is False, so every
  v6 test skips); `gethostbyname_ex`, `if_nameindex` and friends,
  `sethostname`; the address families and option constants the build machine
  has (`AF_CAN`, `AF_ALG`, `AF_VSOCK`, UDPLITE, ... -- 275 names missing from
  `socket`); `socket.makefile` in text mode.  About sixty network-resource
  tests skip here and pass in the control, for the name-resolution reason
  above.
- **`posix`, ~250.** The whole `*at` family and `dir_fd=` (`supports_dir_fd`
  is empty, so `os.fwalk` is absent: 30); `posix_spawn` / `posix_spawnp` (43);
  `openpty`, `forkpty`, `login_tty` (21, plus `pty`); `system`, `mkfifo`,
  `mknod`, `statvfs`, `getrandom`, `wait3`/`wait4`/`waitid`, `readv`/`writev`/
  `preadv`/`pwritev`, `splice`, `copy_file_range`, `sendfile`, `eventfd`,
  `memfd_create`, the xattr calls, the scheduler calls, `setgroups`/
  `initgroups`/`setres*id`, `confstr`, `chroot`, `fchown`, `times_result`.
  138 names in all; `shutil.disk_usage` is missing because of `statvfs`.
- **`signal`, ~30.** `pthread_sigmask`, `pthread_kill`, `sigwait`,
  `sigwaitinfo`, `sigtimedwait`, `sigpending`, `SIGRTMIN`/`SIGRTMAX`.
- **`subprocess`.** `umask=`, `user=`, `group=`, `extra_groups=`,
  `process_group=` raise NotImplementedError though the syscalls now exist.
- **`select`, `time`, `mmap`.** A handful of constants each; `clock_settime`.
- **`faulthandler`, 33.** Reports nothing for a real fault.  Needs a handler
  that walks the frame chain from signal context with raw `write(2)`.

### Phase 3 -- Builtin callables and what introspection sees

One model change with a wide reach: `inspect`, `pydoc`, `doctest`, `pickle`,
`unittest.mock` and Argument Clinic's tests all ask builtins what they are.

- **Four callable types, not one.** `type(len)`, `type(str.upper)`,
  `type(int.__add__)`, `type("".upper)` and `type((1).__add__)` are five
  different answers in CPython and two here.  `types.MethodDescriptorType`,
  `WrapperDescriptorType`, `MethodWrapperType` and `BuiltinMethodType` lack
  `__objclass__`, `__self__`, `__get__`, `__name__` in their own `dir()`.
- **`__text_signature__` and `__doc__`.** No builtin has either:
  `inspect.signature(len)` raises, `help()` has nothing to show, `type` has no
  `__text_signature__`.  The source for both is CPython's clinic output.
- **`__module__` of a module-level builtin** is always `builtins`
  (`math.log.__module__`), so pickling one by reference fails.
- **A Python stand-in for a C function binds as a method.** `io.open` stored
  as a class attribute becomes a bound method; CPython's does not.  That is
  ~100 `test_io` failures, and the same trap waits in every `lib/` module.
- **Slot-only attributes are invisible to `dir()` and `hasattr` on the type.**
  `re.Match.group`, `os.stat_result.st_size`, `SyntaxError.lineno`,
  `types.TracebackType.tb_frame`, `types.CodeType.co_lines`,
  `types.MethodType.__func__` and several hundred more exist on instances and
  are absent from the type's dict.  The structseq types miss `n_fields`,
  `__match_args__` and the tuple protocol in `dir()`.
- **Function objects** lack `__builtins__` and `__type_params__`; `type` lacks
  `__annotations__`, `__type_params__`, `__abstractmethods__`.
- Yield: `test_inspect` 61, `test_doctest` 67, `test_pydoc` 31, `test_io` 89,
  `test_clinic` 50, plus shares of `test_pickle`, `test_functools`,
  `test_descr`, `test_funcattrs`, `test_structseq`.

### Phase 4 -- Code objects, the compiler's public face, tracing

- **Code-object parity.** `co_lines()` and `co_positions()` now return
  iterators. `test_dis` still fails at import because a fixture finds
  an integer where CPython's constants tuple contains a nested code object.
- **`dis.stack_effect`** (`_opcode`), `co_lnotab`, `_varname_from_oparg`,
  `code.replace()` for the three name tuples.
- **The optimiser.** No constant folding (`2 * 3` stays two constants),
  `-O`/`-OO`/`optimize=` do nothing (`assert` still runs, `__debug__` is True,
  docstrings stay), comprehensions are not inlined (PEP 709; `super()` inside
  one is a NameError).  `test_peepholer` asserts all three.
- **`ast`.** Node classes have no `__match_args__` (39 in `test_ast`);
  `feature_version` and type comments are accepted and ignored
  (`test_type_comments` 10); `compile()` of source with a NUL byte has the
  wrong message.
- **Tracing.** `frame.f_lineno` cannot be assigned, so `pdb`'s `jump` and
  `JumpTestCase` fail (61 errors, two of which loop until memory runs out);
  trace events differ on 176 `test_sys_settrace` assertions; `test_pdb` 41,
  `test_bdb` 5, `test_cprofile` 20.  **A keyword call made while a trace or
  profile function is installed hands its keywords to that function**:
  `bytes.decode("utf-8", errors="replace")` under `cProfile` raises
  `Profiler._dispatch() got an unexpected keyword argument 'errors'`, and a
  tracer sees `capture_locals=` the same way.  That is a defect in the
  dispatch, not a missing feature, and it is what kills `test_cprofile` at
  import.  Assigning `f_lineno` is
  CPython's `frame_setlineno`: `marklines`, then `mark_stacks`, an abstract
  interpretation of the block stack to a fixpoint.
- **`sys.monitoring`** (PEP 669) is absent; `sys.audit` hooks never fire
  (`test_audit` 20).
- **`tokenize`**: 26 failures, mostly errors that should be `TokenError`.

### Phase 5 -- Generics and typing

- `types.GenericAlias`: cannot be weak-referenced, cannot be pickled,
  `GenericAlias(origin, args)` miscounts its arguments on the reduce path, and
  `__args__`, `__origin__`, `__parameters__`, `__getitem__`, `__iter__`,
  `__instancecheck__` are missing from the type.  `types.UnionType` likewise.
- `isinstance(x, typing.Union[...])` and `issubclass` refuse a `typing` union.
- `Generic` subclasses fail "is not a generic class" on several subscription
  shapes, including `Unpack` / `TypeVarTuple` forms; `class C[T](*bases)` gets
  no `Generic[T]` base.
- Yield: `test_typing` 138, `test_types` 20, `test_genericalias` 12,
  `test_isinstance` 16, shares of `test_dataclasses` and `test_functools`.

### Phase 6 -- The command line and start-up

- **Interactive mode.** Incomplete-input compilation and continuation,
  `PYTHONINSPECT`, `PYTHONSTARTUP`, and `readline`.
  See `test_repl`, `test_code_module`, and `test_readline`.
- **Flags that are rejected:** `-V`, `-VV`, `-x`, `--help-env`,
  `--help-xoptions`, `--help-all`, `--check-hash-based-pycs`, and any `-X` or
  `-W` written without a space (`-Xutf8`, `-Wd`).  The last alone is 65
  failures: CPython's test helpers pass `-X faulthandler -I -Xutf8` to every
  child.
- **Flags accepted and ignored:** `-O`, `-OO`, `-bb` (no BytesWarning), `-R`,
  `-X utf8`, `-X dev`, `-X faulthandler`, `-X tracemalloc`,
  `-X int_max_str_digits`, `-X pycache_prefix`, `-X warn_default_encoding`;
  and the environment forms `PYTHONOPTIMIZE`, `PYTHONHASHSEED`,
  `PYTHONIOENCODING`, `PYTHONUTF8`, `PYTHONVERBOSE`, `PYTHONDEVMODE`,
  `PYTHONPYCACHEPREFIX`, `PYTHONBREAKPOINT`, `PYTHONINTMAXSTRDIGITS`,
  `PYTHONFAULTHANDLER`, `PYTHONTRACEMALLOC`.
- **Running things that are not a file:** a directory or zip with
  `__main__.py`, and a script on stdin with no `-`.  A missing script exits 1
  where CPython exits 2.
- **Standard streams.** `sys.stdout` has no `reconfigure` (48 failures in
  `test_regrtest`), its `.buffer` is a `FileIO`, its repr is `<stdout>`.  Make
  the three streams real `TextIOWrapper`s over `BufferedWriter`s; the cost was
  measured at 1-3 ms of start-up and needs paying down, not avoiding.
- **`sys`.** `stdlib_module_names`, `monitoring`, `getdlopenflags`,
  `_current_exceptions`; `sys.hash_info.algorithm` and the hash values for
  str and tuple differ (`test_hash`, `test_tuple`).
- Yield: `test_tools` 34, `test_cmd_line` 30, `test_cmd_line_script` 47,
  `test_regrtest` 56, `test_runpy`, `test_utf8_mode`, `test_source_encoding`
  15, `test_subprocess` 20, `test_site`.

### Phase 7 -- Language semantics and diagnostics

- **Generators and coroutines.** `send(non-None)` to a fresh generator is
  accepted; a finished coroutine can be awaited again; PEP 479 is not applied
  (a `StopIteration` escaping a generator stays one); `RuntimeWarning: never
  awaited` is never issued; `test_yield_from` segfaults after "generator
  already executing".  `test_asyncgen` 29, `test_coroutines` 29,
  `test_generators` 10.
- **Finalisation warnings.** No `ResourceWarning` for an unclosed file or
  socket (`test_io`, `test_fileio`, `test_socket`, `test_logging`).
- **Errors the compiler does not raise.** `test_except_star` 33,
  `test_named_expressions` 20, `test_exceptions` 40, `test_syntax` 22,
  `test_grammar` 13, `test_positional_only_arg` 13, `test_scope`,
  `test_global`, `test_string_literals`, `test_eof`, `test_future_stmt` 9.
  f-string field errors have two messages where CPython has a dozen, reported
  at the token rather than in the field (`test_fstring`, 85 once it stops
  running out of memory).
- **Object model.** `obj.__class__ = int` is accepted; a dict subclass used as
  `exec()` locals does not have `__getitem__` consulted; exceptions and
  `__notes__`; `RecursionError` in `isinstance` chains; `test_descr` 53,
  `test_builtin` 62, `test_class`, `test_super` 13, `test_property` 12,
  `test_weakref` 29, `test_gc` 25, `test_finalization` 10.
- **Tracebacks.** `test_traceback` 50 failing, 122 more behind `cpython_only`.
- **Buffer protocol.** A view through `tp_as_buffer` is read-only bytes with
  no format; no shaped `cast`; PEP 688 `__buffer__` works for a Python class
  but `mmap` exports none (so `re.search(pat, mmap)` fails), and `bytes`,
  `bytearray`, `memoryview`, `array` lack `__buffer__` /
  `__release_buffer__`; `PickleBuffer` is not accepted by `memoryview`.
  `test_memoryview` 11, `test_buffer` 13, `test_picklebuffer`, out-of-band
  pickle (~90 failing subtests).
- **Arithmetic.** `2**(2**70)` answers 1; `bytearray.extend(5)` is accepted.

### Phase 8 -- The long tail

Everything left is a module a handful of tests short.  266 file modules have a
gap; 156 of them are within ten tests and sum to about 580.  The larger ones:

`test_re` 52, `test_pickle` 58 and `test_pickletools` 16 (classes found by
qualified name, `reversed`/`map`/`zip` pickling), `test_codecs` 34 and
`test_codeccallbacks` 17 (error-handler edge cases), `test_bytes` 36,
`test_datetime` 30 (`_datetime` reprs), `test_csv` 26 (`Reader`/`Writer`
types), `test_unicode` 24, `test_marshal` 29, `test_sys` 46, `test_zlib` 21,
`test_memoryio` 24, `test_time` 24, `test_locale` 35, `test_file` 16,
`test_binascii` 16, `test_deque` 15, `test_exception_group` 14,
`test_threading` 22, `test_math` 16 (`gamma`, `lgamma`, n-ary `hypot` round
differently), `test_iter` 13, `test_dict` 26, `test_range` 13, `test_set` 12,
`test_enum` 12, `test_httpservers` 12, `test_struct` 15 (`e`, the half
float), `test_float` 11, `test_complex` 9.

And in the packages: `test_importlib` 138 (`__import__` with a relative name
"is not supported"; specs that are `None`), `test_email` 61, `test_zipfile` 39
(`resolve_dir`), `test_import` 36, `test_unittest` 29, `test_warnings` 25,
`test_dataclasses` 15, `test_zoneinfo` 13, `test_module` 13, `test_json` 12,
`test_ctypes` 20.

Work these by clustering failure messages across modules rather than module
by module: "TypeError not raised" alone is 124 tests in 31 modules, and most
of them are missing argument validation of one kind.

### Phase 9 -- Debt that blocks nothing and costs something

- **Errors return, finished.** Helpers that return errors without a `Fails:`
  line, so lint does not bind their callers (`obj_richcompare`,
  `obj_richcompare_bool`, `obj_binary_op`, `obj_repr`, `obj_str`,
  `obj_getattr*`, `obj_setattr`, `call_iternext`); fifteen leaking failure
  paths in the raise probe; the handler audit (`op_build_map`,
  `op_dict_merge`, `op_match_keys`, `op_check_exc_match`, `op_import_name`,
  LOAD_ATTR under a raising `__getattribute__`); unwinder repairs that are now
  dead.
- **`V_PACK` / `TAG_*` scaffolding** left from the NaN-box migration.
- **Stack alignment outside the GMP paths** (see defects).
- **GIL coverage:** `ffi_call`, `fsync`, FIFO `open` and compression of a
  large buffer hold the lock; ctypes' `errno` is global; helgrind has never
  been run.
- **Docblocks without a signature line**, ratcheted by
  `tests/docblock_floor.txt`.

## Performance

At or above CPython in aggregate; the mission says "at or above", so these
rows are owed.  Ratios are apython speed over CPython's.

- **Text:** `m_text` 0.79x.  Non-ASCII indexing is O(n) per access
  (`s_getitem_w` 0.33x) because nothing remembers the last code-point
  position; `split` 0.65-0.75x, `join` with a separator 0.60x, decode 0.71x.
- **Big integers:** `i_big` 0.40x, `i_huge` 0.33x, parse 0.79x.
- **Allocation:** `m_binary_trees` 0.95x, `c_new_plain` 0.78x, `c_new_slots`
  0.79x.
- **Lists:** `l_append` 0.54x and `c_append` 0.44x, `l_pop_front` 0.42x,
  `l_from_str` 0.40x, `l_insert_front` 0.56x.
- **Dicts and sets:** `d_setdefault` 0.54x, `d_comp_str` 0.55x,
  `st_from_str` 0.56x, construction from another container 0.65-0.75x.
- **Float parse** 0.56x; `rfind`/`rindex` are still O(n*m).

## Open defects

Carried over from `bugs.md`, each re-run on the date above.  Entries that no
longer reproduced were dropped: the `test.test_module` collector segfault, the
`pdb` hang on a piped stdin, `array`'s unsigned 64-bit range, and the
`__bool__` wording.

- **Calls made with a misaligned stack, everywhere except the paths into
  GMP.**  `INT_NEED_MPZ` calls at the wrong parity in every expansion;
  `V_PACK`'s cold path runs after `leave`, eight bytes out; `dict_lookup`
  enters `obj_richcompare_bool` misaligned and everything beneath inherits it.
  No source-level check can see these.  What works is a CFG walk over the
  *disassembly* tracking rsp from entry, told that an opcode handler is
  entered by `jmp` and so at the opposite parity.  `tests/gmp_align_probe.sh`
  covers the GMP sites only.
- **A builtin's own raise is still a non-local jump**, so a C caller cannot
  absorb it and a builtin `__init__` that refuses its arguments leaks the
  instance.  `python3 src/compiler/raisemap.py` is the map.
- **Attribute lookup is instance-dict-first unless the MRO holds a data
  descriptor.**  Observable only when user code mutates the class during the
  lookup.
- **A dunder's result is type-checked for `__str__`, `__repr__` and
  `__format__` only**; `__hash__`, `__int__`, `__index__` and `__float__`
  results differ from CPython in wording.
- **A relative import with no `__name__` in globals** raises ImportError where
  CPython raises KeyError.
- **Source that is not valid UTF-8** is refused with our own wording, one
  column off for a bad four-byte lead.
- **`co_varnames` of a module code object lists its globals.**
- **Seven syntax errors differ in position**, held in
  `tests/syntax_floor.txt`: `nonlocal` with no binding reports line 0; a
  mapping pattern's non-literal key; five column differences.
- **`super(...).attr` at module level compiles to LOAD_SUPER_ATTR**, which
  CPython emits only inside a function.
- **`marshal.load()` reads the whole stream**, so a file of two objects fails
  on the second.
- **`cmath`** fails two of CPython's `test_specific_values` checks (a signed
  zero and a nan); it is libm's, not CPython's own.

## Divergences to revisit

`DIVERGENCES.md` entries that this audit found costing tests are scheduled
above: the single builtin callable type and bound-builtin `method` (Phase 3),
`mmap`'s missing buffer and `faulthandler` (Phase 2), the narrow buffer slot
(Phase 7), the standard streams and the REPL (Phase 6), `sys.monitoring` and
the un-inlined comprehension (Phase 4), and the accelerator stand-ins
(Phase 1).  Their entries stay in that file for the reasoning until the work
lands.

Entries that were stale or wholly carried here were removed from it: the
`posix` subset, `subprocess` credentials and `marshal.load()` (now above), and
six that no longer reproduced -- the filesystem encoding, the list-backed
deque and generator-function itertools, the class `__dict__` keys, "C code
cannot catch a Python exception", the PEP 563 source slice, and the missing
transform and idna codecs.  What remains is layout and wording that no test
in scope asks about; treat each as a description, not a decision, and re-open
any that a sweep shows costing tests.
