# Deliberate divergences

Places apython answers differently from CPython 3.12 **on purpose**.  Each was
weighed and each was chosen; none is a defect waiting for a patch, and none
belongs in `bugs.md`, which is the list of what is still wrong.

Every entry says what the difference is, why the choice was made, and what
changing it would cost -- so that a later decision to revisit one starts from
the reasoning rather than from scratch.

## Object layout and introspection

- **No managed dicts, so the layout attributes differ for any class that has
  an instance `__dict__`.**  CPython 3.12 keeps a class's instance dict in a
  slot before the object rather than in the object, and reports that as
  `__dictoffset__ == -1` and `__weakrefoffset__ == -32`; the header itself is
  then 16 bytes.  Here the dict is a word inside the instance, so
  `class A: pass` reports a positive `__dictoffset__` and a header one word
  wider.  A `__slots__` class has no dict of its own and matches CPython
  exactly.

  Nothing in Python reads these except code that is measuring the layout, and
  a managed dict is a whole allocation strategy -- the values are honest about
  the layout apython actually has.

- **Weak references live in a side table, not in the object, so
  `__weakrefoffset__` is 0 everywhere.**  The links are kept in one dict keyed
  by the referent's address and `obj_dealloc` consults it, which works and is
  tested; what it cannot do is answer CPython's question, because there is no
  offset to report.

  Putting the head in the object is not the 95-line edit it looks like.  The
  `PyTypeObject` field is the easy part.  The word itself has to go in the
  *instances* of all seventeen static types CPython lets you weak-reference --
  set, frozenset, type and both metatypes, function, builtin, method,
  generator, coroutine, async generator, module, memoryview, code, file,
  BytesIO, Task -- which means a field on each of those structs, a zeroing
  store at each of their forty-odd allocation sites, a release in each
  dealloc, and, because `type` is one of them, a second new `PyTypeObject`
  field and another pass over all 94 tables.  A missed zeroing store is a
  garbage pointer walked as a list.  The whole of it buys one number that
  still would not match CPython's, since the basicsizes it is an offset into
  differ anyway.

## The platform surface

- **`posix` is a subset, and a deliberate one.**  The file, directory and
  process calls `os.py` and `os.path` reach for are there, along with
  `environ`, `stat_result`, `error` and the O_*/W* constants -- enough that
  CPython's own `os.py` imports and works.  What is not: the whole `*at`
  family.  `_have_functions` is an empty list, which is the honest answer --
  no `dir_fd=` support -- and os.py reads it to build `supports_dir_fd`.

  `putenv` and `unsetenv` were on it too, and are not: `os.environ`'s
  `__setitem__` and `__delitem__` call them, so `os.environ["X"] = "1"` was a
  NameError -- and the setUp of CPython's test_argparse does exactly that on
  every one of its four hundred tests.  They are libc's setenv and unsetenv,
  because there is no syscall for the process environment.

  `scandir` and `DirEntry` were on this list and are not any more.  Calling
  their absence deliberate had stopped being true: `os.walk` reaches for
  `scandir` and nothing else, and through it so do `shutil`, `glob`,
  `pathlib` and `tempfile`'s cleanup -- 730 NameErrors across CPython's suite,
  and every one of those modules unusable.

- **An `mmap` object exports no buffer.**  `src/modules/mmap.asm` is the
  mapping -- mmap, munmap, mremap, msync, madvise, the raw bytes and the
  search over them -- and `lib/mmap.py` is the object, on the split
  `_zlibcore`/`zlib` and `_iocore`/`_io` already use.  A Python class has no
  `tp_as_buffer`, so `memoryview(m)` refuses, and so does anything that asks
  for one: `re.search(pat, m)` is the case CPython's own test_mmap uses, and
  it is the single test of the forty-six that still fails.

  Reading and writing through the object's own syntax is unaffected -- `m[i]`,
  `m[a:b]`, `m[a:b] = data`, `read`, `write`, `find`, `move`, `flush`,
  `resize`, `madvise` -- which is what the stdlib's own users of mmap do.
  Closing it would mean either a real assembly type with a buffer slot, or
  PEP 688's `__buffer__` honoured for Python classes; the second is the
  smaller of the two and would also serve every other `lib/` stand-in, so
  that is the way in if it is ever wanted.

- **`faulthandler` reports deliberate faults, and is silent for a real
  crash.**  CPython's is a C module and has to be: its whole point is to
  report a crash, and by then calling into the interpreter is not safe -- its
  handler writes the traceback from the signal context itself.  `lib/`'s is
  Python over the `signal` module, so its handlers run the way every
  Python-level signal handler in this tree runs: the C handler records the
  signal and the eval loop delivers it at the top of an instruction.

  That is enough for a signal a program RAISES -- `register(SIGUSR1)` really
  does dump -- and for `dump_traceback_later`, which is `setitimer` with
  SIGALRM and really does fire.  It is not enough for a genuine SIGSEGV: the
  process is already somewhere the eval loop will not be reached, so the
  report never comes.

  Writing it in assembly would not be enough either; it would have to walk
  r12's frame chain from the signal context and write with a raw `write(2)`,
  never touching the allocator or the eval loop.  That is a real piece of
  work for a report that only matters when the interpreter has already
  failed, and having the module at all is what 113 of test_regrtest's tests
  were waiting on.  `all_threads` is accepted and ignored: the dump is of the
  calling thread only.

- **`sys.getfilesystemencoding()` always answers `'utf-8'`.**  PEP 540's
  locale handling does not exist, and neither does the `surrogateescape`
  error handler, so a filename or environment value that is not valid UTF-8
  does not survive a decode/encode round trip, where CPython preserves it.
  The other half of why is in `bugs.md`: the codecs the interpreter can spell
  itself are utf-8, ascii and latin-1, and `surrogateescape` is not among the
  error handlers any of them accept.

## Performance, where the answer is already right

- **`collections.deque` is list-backed, and two itertools functions
  materialise.**  CPython's deque is a block-linked list, so `appendleft` and
  `popleft` are O(1) there and O(n) here; `itertools.groupby` materialises
  each group rather than sharing the source iterator, and `tee` materialises
  the source.  Every observable answer matches for a finite iterable.

- **`itertools`' functions are functions, where CPython's are classes.**
  `lib/itertools.py` writes all but `chain` as generator functions, so
  `type(itertools.count(1))` is `generator` rather than `itertools.count`,
  `isinstance(x, itertools.count)` is a TypeError rather than an answer, the
  reprs read as a generator's, and none of them pickle -- CPython's each carry
  a `__reduce__`.

  Every VALUE they produce is CPython's; what differs is what the iterator
  itself says it is.  Closing it means eighteen classes with `__iter__`,
  `__next__`, `__reduce__` and `__setstate__` apiece, in place of eighteen
  `yield` statements, for introspection that only CPython's own test_itertools
  asks about.  `chain` is a class already, because `from_iterable` needed
  somewhere to live.

- **bytearray's read-only methods copy.**  bytes keeps its data inline and
  bytearray keeps it out of line, so the shared method bodies cannot read a
  bytearray directly; each wrapper builds a temporary bytes, runs the bytes
  body and releases it.  Correct, and cheap for a scratch buffer, but it is
  an allocation per call -- worth threading a (pointer, length) pair through
  the bodies if bytearray ever becomes hot.

- **Unbound builtin wrappers share the `method_descriptor` type.**
  CPython distinguishes `wrapper_descriptor` from `method_descriptor`.
  apython uses the same descriptor type for `list.append` and
  `list.__len__`. Each carries its owning class and implements the same
  binding and reduction protocol. Module-level builtin functions have
  their own type, so multiprocessing can register a descriptor reducer.

- **A class's `__dict__` does not carry `__dict__`, `__weakref__` or
  `__doc__`, and does carry `__qualname__`.**  CPython's `type_new` adds the
  first two as getset descriptors, sets `__doc__` to None when the body has
  no docstring, and moves `__qualname__` out of the dict onto the type.  Here
  the two descriptors do not exist -- they are the instance-dict and weakref
  layout recorded above -- `__doc__` is answered by a fallback rather than
  stored, and `__qualname__` stays in the dict because there is no field on
  the type to move it to.  Every one of those attributes reads correctly
  through the class; it is only `sorted(C.__dict__)` that differs.

- **A dict does not share its key table, so `gc.get_referents` reports its
  keys.**  CPython gives a dict whose keys are all strings a shared key table
  that the dict does not own, so its `tp_traverse` does not visit the keys and
  `gc.get_referents({"a": 1})` answers with the values alone.  Here the keys
  are the dict's own and are reported, which is what the traverse honestly
  walks.  Sharing key tables is a whole second dict layout, and the number it
  would buy is a report about the layout rather than about the program.

- **`gc.freeze()` moves nothing.**  CPython's permanent generation exists so
  that a program can freeze everything alive after startup and stop the
  collector dirtying those pages -- which matters to a forking server and to
  nothing else.  There is no permanent generation here; `freeze()` runs a
  full collection, `get_freeze_count()` stays at zero, and `unfreeze()` has
  nothing to undo, which is exactly what a program calling the pair in
  sequence would see either way.

## `pwd` and `grp` read the files, where CPython's go through NSS

CPython's are C modules over `getpwnam(3)` and `getgrnam(3)`, which consult
`nsswitch.conf` and so can answer from LDAP, SSSD, systemd-homed or anything
else configured there.  These read `/etc/passwd` and `/etc/group` directly,
which is what NSS resolves to on an ordinary machine and nothing more.

What it costs is a host whose users are not in the file: every lookup here is
a `KeyError` where CPython's would have found the entry.  What it buys is that
the modules exist at all -- `getpass`, `shutil.chown`, `tarfile`'s ownership
restore and `os.path.expanduser` all import one of them, and `import pwd`
failing took each of those with it.

Reaching NSS properly means `dlopen`ing the `libnss_*` modules and calling
through their ABI, which is a project rather than a module.

## `syslog` writes to `/dev/log` itself, where CPython's calls libc

CPython's module is a wrapper on `openlog(3)`/`syslog(3)`/`closelog(3)`, which
are themselves a few dozen lines around a datagram socket: connect to
`/dev/log`, write `<priority>tag[pid]: message`, drop the message if nothing
is listening.  `lib/syslog.py` does that directly, so the priority arithmetic,
the mask, the ident and the option flags are all the same and no new C entry
point was needed.

Two things libc does that this does not: the `SOCK_STREAM` fallback for the
few systems whose `/dev/log` is a stream socket, and `LOG_CONS`, which writes
to `/dev/console` when the socket cannot be reached.  Neither is observable
from Python -- a message that cannot be delivered is silently dropped either
way, which is `syslog(3)`'s own contract -- so what a program sees differs
only on a host where the console fallback would have been the only delivery.

## `_lsprof` is Python over `sys.setprofile`, so it profiles itself

CPython's profiler is C hooked into the same slot, and its own machinery costs
nothing measurable.  `lib/_lsprof.py` is Python: the dispatch function runs
per event, so a profiled run is slower here than there, and one row --
`Profiler.disable`, which `cProfile.create_stats` calls -- appears as a Python
frame where CPython reports `<method 'disable' of '_lsprof.Profiler'
objects>`.  Every other row, and all four numbers in each, match: the
`totaltime`/`inlinetime`/`callcount`/`reccallcount` arithmetic is CPython's,
including that a recursive call adds to the two counts and not to
`totaltime`, and a builtin is named by `normalizeUserObj`'s rule rather than
by its repr.

## `f_trace_opcodes` works, and CPython 3.12's does not

`sys.settrace` plus `frame.f_trace_opcodes = True` delivers an `'opcode'`
event per instruction here.  CPython 3.12 accepts the assignment and then
never delivers one: PEP 669 moved instrumentation under the legacy hook and
the opcode event did not come with it.  3.11 delivered them and 3.13 does
again, so this matches Python either side of 3.12 rather than 3.12 itself.

Costing nothing was the deciding argument.  The dispatch thunk already runs at
every instruction while tracing is on, so the event is one more test in a
function that is already there -- where CPython needs a separate interpreter
state flag and thirteen `INSTRUMENTED_*` opcodes.  Refusing to deliver it
would have been extra code to reproduce a regression.

`tests/test_settrace.py` compares every other event against CPython and
deliberately filters `'opcode'` out of the one case that asks for it.

## Interpreter structure

- **C code here cannot catch a Python exception.**  `raise_exception`
  tail-jumps into `eval_exception_unwind`, which resumes the eval loop from
  saved globals rather than returning through the C stack, so a `call` to a
  slot that raises never comes back.  `str.translate` gets around it by
  reaching a heaptype table through `dunder_call_2`, which does return; the
  general limit stands, and is why the `bytes %` leak recorded in `bugs.md`
  cannot be fixed by catching.

## A buffer reached through `tp_as_buffer` is a read-only view of BYTES

`PyTypeObject` carries a `tp_as_buffer`, and it answers one question -- where
the memory is and how much of it there is.  CPython's `Py_buffer` answers six
more: the item format, the item size, the shape, the strides, the suboffsets
and whether the consumer may write.  So a `memoryview` obtained through the
slot differs from CPython's in two ways:

- It is **read-only**, because the slot has no way to say otherwise: CPython's
  consumer asks for write access and the exporter grants or refuses it, and
  there is no request here to carry that in.  A write is refused rather than
  guessed at.  (Where the bytes may MOVE is a separate question, and the slot
  does answer it: a view acquires an export and the exporter refuses a resize
  while one is outstanding, which is why `a.append(x)` under a live view raises
  BufferError exactly as CPython's does.)
- It is a view of **bytes**: `format` is `'B'` and `itemsize` is `1`, so
  `len(memoryview(array('i', [1, 2])))` is 8 here and 2 in CPython, and
  indexing yields a byte rather than an item.  `bytes(m)` and `m.tobytes()`
  agree exactly, which is what every caller of `bytes_like_ptr_len` actually
  reads.

The second is now only half true.  `cast()` handles the native format codes --
signed and unsigned integers of every width, `f`, `d`, `?` and `c` -- so a
view MADE by cast() decodes its items correctly.  What a view obtained through
the SLOT reports is still `'B'` and itemsize 1, because the slot has no field
to carry a format in: widening it means a new calling convention and every
`bytes_like_ptr_len` caller with it.

Two things remain absent inside `memoryview` itself, and neither is what the
slot's narrowness forces:

- **A shaped cast.**  `cast(fmt, shape)` ignores the shape, so `ndim` is
  always 1 and `shape` a 1-tuple.  CPython refuses multi-dimensional
  sub-views and iteration outright -- `m[0]` on a 2-D view is a
  NotImplementedError there -- so what is missing is `ndim`, `shape`,
  `strides`, a nested `tolist()` and a tuple index.  Measured against
  CPython's own test_memoryview, it buys nothing: not one of that module's
  remaining failures here mentions shape or ndim.  Recorded rather than
  built for exactly that reason.
- **`e`, the half-float.**  The one native code `cast()` refuses and CPython
  accepts.  Its decode is a bit layout rather than a load.

## `sys.stdout.buffer` is a FileIO beside the text half, not underneath it

`sys.stdout` is the assembly file object, which writes to its descriptor
directly and keeps its own 8 KB buffer; CPython's is a `TextIOWrapper` sitting
ON a `BufferedWriter`, and `sys.stdout.buffer` IS that writer.  Here the binary
half is an `_io.FileIO` over the same descriptor, built the first time it is
asked for and kept.

It is built lazily because building it eagerly means importing `_io` before
anything runs, and that is **1.1 ms to 2.9 ms on every invocation** of the
interpreter -- measured, not estimated.  Only a program that asks for the
binary half pays for it.

Two consequences.  `type(sys.stdout.buffer).__name__` is `FileIO` rather than
`BufferedWriter`.  And because the two halves reach one descriptor
independently rather than one sitting on the other, handing out the binary half
turns the text half's buffering OFF -- which keeps

    print("one"); sys.stdout.buffer.write(b"two\n"); print("three")

in program order, where CPython, whose buffered text is flushed last, emits
`two` first.  Giving up the buffering is the cheaper of the two wrongs: a
program that mixes the halves is asking about order, and one that does not
never reaches the rule.

Making `sys.stdout` a real `TextIOWrapper` over a real `BufferedWriter` closes
all of it, and costs the start-up above.

`array.frombytes` is the one place the narrow model is visible in the other
direction.  CPython asks for `PyBUF_SIMPLE`, which an exporter carrying its own
format declines, so `a.frombytes(another_array)` is a TypeError there -- and
since the slot does not model the request flags, the three types CPython
accepts in practice are named instead of asked.

## Test oracles

Three tests compare against a recorded transcript in `tests/expected/` rather
than against CPython, because CPython cannot serve as an oracle for them:

- `test_sre.py` feeds hand-written SRE bytecode to `_sre.compile()`, a
  private API that does not validate its input; CPython segfaults on the
  group pattern it uses.
- `test_traceback_carets.py` and `test_unraisable.py` both let an exception
  be reported on stderr, and the report names the file: CPython absolutizes
  the path of a script it runs directly and a run from a `.pyc` does not.
  That is now the only difference between them and CPython.  stdout is
  block-buffered here as it is there, and flushed before an uncaught
  exception's report, so the two streams interleave the same way; every
  other line of both matches CPython 3.12 byte for byte.

Any *new* recorded-oracle test needs the same justification, or it risks
blessing a divergence instead of catching it.

## Threads run under a GIL, with these differences

Threads are real: `_thread.start_new_thread` starts a pthread, one thread at a
time runs Python under a global interpreter lock (`src/gil.asm`, a port of
CPython's `ceval_gil.c`), and CPython's own `threading.py`, `queue.py` and
`concurrent.futures` run on it unchanged.  What differs from CPython:

- **Signals are blocked in every thread but the main one.**  CPython leaves
  them deliverable anywhere and only *runs handlers* on the main thread; here
  the kernel delivers to the main thread to begin with.  A program sees the
  same thing -- handlers run on the main thread -- unless it inspects another
  thread's signal mask.
- **`socket.recv_into` with a positive timeout releases the buffer while
  waiting for readiness.** Each receive pins the buffer for the syscall.
  If it would block, the Python socket wrapper waits and retries with a new
  export. CPython holds one export across the entire wait.
- **Not every blocking call gives up the GIL.**  The ones that do are sleep,
  lock waits, `read`/`write`, the socket calls, `poll`/`epoll`, `connect`,
  `waitpid`, `flock`, `pause`, `input()` and the four OpenSSL calls that do
  socket I/O.  `open()` on a FIFO, `fsync`, compression of a large buffer and
  a ctypes foreign call still hold it.
- **`_thread._local`, `RLock` and the lock type are Python classes** over
  `_threadcore`, where CPython's are C types.  Their behaviour is the
  stdlib's; their `type()` is an ordinary class.
- **A thread's frame region is smaller than the main thread's**, so very deep
  recursion in a secondary thread falls back to the general frame pool
  sooner.  It is slower there, not different.

## The CJK codecs are Python shims

The multibyte codec modules use Python state machines and lazy maps generated
from CPython 3.12.9. The standard-library encoding wrappers use their existing
codec, incremental and stream interfaces. The CPython internals that pass
mapping and codec capsules between C extensions are specific to that ABI.

## sys.monitoring is absent

PEP 669's monitoring API has no implementation here.  `sys.settrace` and
`sys.setprofile` are, which is what `pdb`, `trace` and every coverage tool
older than 3.12 use; `sys.monitoring` is the newer interface over the same
events and needs per-code-object instrumentation that this interpreter's
dispatch does not have a place for yet.

## There is no REPL

`./apython` reads a file, `-c`, `-m` or stdin.  There is no interactive
prompt.  `CMODE_SINGLE` and `sys.displayhook` both exist, so starting one is
cheap and finishing one -- line continuation, the input hook, readline, the
traceback rules an interactive statement has -- is not; it is its own
feature rather than a missing piece of this one.

`-i` is refused with the usage message, which is where this costs something
measurable: `test_cmd_line_script`'s `interactive_python` helper is

    while True:
        data = stderr.read(4)
        if data == b">>> ":
            break
        stderr.readline()

and a subprocess that exited leaves both calls answering `b''` forever, so
the four REPL-flush tests spin rather than fail.  The module reports nothing
either way -- it did not import at all before `_frozen_importlib_external`
arrived -- so nothing is lost by it, but it is why that module is a HANG in
the sweep rather than a row of failures.

## The alias modules in lib/

`_datetime`, `_json`, `_pickle` and `_decimal` are stand-ins for CPython's C
accelerators, and each says so in its own header.  They exist because
`test.support.import_fresh_module` returns **None** when a module in its
`fresh` list cannot be imported, and a test file that then reads
`module.__dict__` dies while its body is still executing -- taking every test
in the file with it.

None of them is faster than what it re-exports, and no number measured
through one should be read as native speed.  `_pickle` is the exception to
its own rule: it carries `PickleBuffer`, which is a TYPE rather than an
accelerator and which `pickle.py` imports at module scope.

Each has to answer for **both** halves of the arrangement it is standing in
for, and getting that wrong is not a smaller divergence -- it is a module
that dies at import.  `import_fresh_module` is used twice per test file, once
with the accelerator blocked and once with the pure module blocked, so a
stand-in that merely re-exports the pure one fails the second call and takes
the whole file with it.  `_datetime` therefore reads `_pydatetime`'s SOURCE
when the import is refused: blocking a module stops `import`, not `open`.
And `import _pickle` succeeding means `from _pickle import dump, ...` has to
succeed too, so the nine names CPython publishes are forwarded through PEP
562's module `__getattr__` -- deferred, because `pickle.py` reaches for
`PickleBuffer` before it has a Pickler to forward to.  What comes back is
`pickle`'s own object, so there is still exactly one implementation.

`_testcapi` and `_testinternalcapi` are the same arrangement for CPython's
test harness: every name in them answers a true fact about this interpreter
or raises NotImplementedError, and nothing pretends to exercise a C API that
is not here.

## PEP 563 stores a raw source slice, not an unparse

`from __future__ import annotations` makes every annotation a string of its
own source text, and this tree takes that string by SLICING the file between
the annotation node's start and the end its AstSpan records.  CPython stores
what its own unparser produces from the same node.

The two agree for every ordinary annotation and differ in three ways:
redundant parentheses survive here (`x: (int)` is `'(int)'` rather than
`'int'`), a multi-line annotation keeps its newlines and indentation, and a
string literal keeps the quote it was written with (`x: "s"` is `'"s"'` here
and `"'s'"` there).

The string still evaluates to the same object, which is what
`typing.get_type_hints` and every other consumer does with it.  Matching the
unparser exactly means writing one -- `lib/ast.py`'s `unparse` is present to
diff against if it is ever wanted.

`class C[T](*bases)` is the one shape that does not get its `Generic[T]`
base: the starred form builds its base tuple with CALL_FUNCTION_EX, and one
more element has to go into the tuple rather than onto the stack.  Every
written-out base list gets it.

## A builtin method bound to an instance is a `method`

`"x".upper` is a `builtin_function_or_method` in CPython and a `method` here.
Both are callable, both carry `__self__`, both repr as
`<built-in method upper of str object at 0x...>`, and both answer the same
`__name__` and `__qualname__`; what differs is `type()`.

CPython binds a builtin by making a copy of the descriptor with its receiver
stored inside it, which is why the type does not change.  Here the ordinary
bound-method object does the work, which is one object type instead of two
and one calling convention instead of two -- `method_call` prepends `im_self`
and dispatches through `im_func`'s `tp_call`, exactly as it does for a Python
function.

Changing it means a `func_self` field on `PyBuiltinObject`, a bound/unbound
distinction in `builtin_func_call`, and a second repr; the gain is the name
`type()` prints.

## `subprocess` cannot change the child's credentials, and says so

`_posixsubprocess.fork_exec` takes CPython's twenty-two arguments.  The ones
that decide what the child sees are honoured: the executable list, the three
pipes, the working directory, the environment, `close_fds`,
`start_new_session` and `preexec_fn`.  `restore_signals` is honoured by
having nothing to restore -- this interpreter installs no handlers, so a
child starts with the dispositions it inherited, which is what the flag asks
for.

The five to do with credentials -- `uid`, `gid`, `gids`, `umask` and
`process_group` -- raise `NotImplementedError`.  That is the divergence, and
it is deliberate: there are no setuid, setgid or setpgid syscalls here, and a
caller who passed `user=` to drop privileges must not be handed a child that
quietly kept them.  Refusing to run is the safe answer; running as root when
asked not to is not.

## A comprehension keeps a frame of its own

PEP 709 inlines a list, set or dict comprehension into the block it is
written in.  This does not: every comprehension gets a code object, a call
and a frame, which is what CPython did through 3.11.

It was inlined for a while, and taken out again because it cannot be done
correctly on a symbol table that classifies a name once per scope.  Inlining
needs the target to be a fast local of the ENCLOSING scope while every other
meaning of that name stays what it was, and CPython gets that by giving one
name two storages at once: for

    x = 5
    y = [x for x in range(3)]

its module code object carries `x` in co_varnames AND in co_names, and
decides which at each USE.  Saying only one of those redefined the name for
the whole block, and three things followed -- `[i for i in r]` beside any
other `i` took the other one over and left it unbound; a target the block
declared `global` had no fast slot for LOAD_FAST_AND_CLEAR to name, so the
oparg was -1; and a target captured by a nested lambda became a cell that
LOAD_FAST_AND_CLEAR then wrote through as though it were not.  Two of those
were segfaults, in the most ordinary comprehension there is.  Expressing it
properly means a per-USE classification, which is a larger change than the
effects it buys.

What it costs, and all it costs:

- `sys._getframe().f_code.co_name` read from inside one answers `<listcomp>`
  rather than the enclosing function's name, and a traceback through one has
  an extra entry.
- Zero-argument `super()` inside one raises NameError, because a nested
  function has neither `__class__` as a free variable nor the method's
  `self` as its first argument -- the first argument is the implicit `.0`.
  CPython 3.11 raised the same error for the same reason.  `super(C, self)`
  works.

Everything else about a comprehension matches, including that the target
does not leak, that the outermost iterable is evaluated in the enclosing
scope, and that a generator expression keeps its own frame in both.
`tests/test_comprehension_inline.py` pins the pair, so the day the symbol
table can hold two storages there is something to measure against.

## The codecs that are neither a table nor a state machine

`encodings/` here is one module and one generated table file rather than
CPython's two hundred modules, and it answers for every codec that is a flat
256-entry mapping: the cpNNN and iso8859-N pages, koi8, the mac_* family,
tis-620, the EBCDIC cp037 group.  `_codecs` answers for the ones that are a
state machine instead -- utf-8 and its BOM'd form, ascii, latin-1, the six
fixed-width UTF-16 and UTF-32 forms, utf-7, the two escape codecs.  The multibyte CJK codecs use their own mapping data and state machines.
The remaining differences include:
- **The transform codecs** -- base64_codec, hex_codec, quopri_codec,
  uu_codec, rot_13, zlib_codec, bz2_codec.  These are bytes-to-bytes and are
  not text encodings: CPython refuses `"x".encode("base64")` too.  Reaching
  them means `codecs.encode`, and `codecs` is not here either; two of them
  additionally need zlib and bz2, which are not.
- **punycode, idna and mbcs.**  idna needs `unicodedata`'s nameprep tables,
  which are the same argument as the CJK ones; punycode exists only to serve
  idna; mbcs and oem are Windows-only and absent on any Linux CPython too.

An unknown codec is a LookupError with CPython's wording, so a program that
catches one behaves the same either way.

## code.replace() cannot change co_varnames, co_freevars or co_cellvars

Every other field CPython's `code.replace()` accepts is here: the seven
counts and flags, the bytecode, the constants and names, the three strings,
and the two side tables.  The three that are refused are the ones this code
object does not store.  CPython keeps `co_varnames`, `co_cellvars` and
`co_freevars` as three tuples; this keeps one `co_localsplusnames` with a
parallel `co_localspluskinds` string saying which of the three each name is,
which is the 3.11 layout and what the frame's `localsplus` is addressed by.
Replacing one of the three therefore means rebuilding both, and validating
that the result still describes the same frame.

Nothing in CPython's own standard library replaces them -- `types.coroutine`
changes `co_flags`, and that is the only use of `replace()` the library
makes -- and a caller that changes a variable name without changing the
bytecode that addresses it has broken the code object either way.  They raise
a TypeError naming all three rather than "unexpected keyword argument", so
the message says what is missing rather than pretending the field does not
exist.

## `platform.python_implementation()` answers `CPython`

`sys.version` is `3.12.0 (apython 0.6.0) [NASM x86-64]`, and the bracketed
compiler field at the end is there because `platform._sys_version` will not
parse the string without one -- its regex ends in `\[([^\]]+)\]?`, and every
call into `platform` raised `ValueError: failed to parse CPython sys.version`
while the field was missing.  `platform` is reached by a great deal of
ordinary code; `test_wsgiref`'s thirty-five tests all ended there.

What the string cannot do is say `apython`.  `python_implementation()` is
`_sys_version()[0]`, and the name is chosen before the regex runs, by three
hardcoded probes: `sys.platform.startswith('java')` gives `Jython`, `"PyPy" in
sys.version` gives `PyPy`, and anything else gives `CPython`.  There is no
hook, and the PyPy branch additionally demands a `[PyPy ...]` bracket and a
`(#buildno, builddate, buildtime)` triple -- so the only two answers available
are `CPython` and a `platform` module that does not work at all.

`sys.implementation.name` is `apython` and is the attribute a program should
read; `sys.implementation.cache_tag` stays `cpython-312`, because that is what
names the `.pyc` files this interpreter reads and writes.

## `type.__flags__` reports a subset of CPython's Py_TPFLAGS_*

`tp_flags` cannot be handed back raw -- the low 32 bits are this tree's own
layout and the high 32 are the type version -- so `__flags__` translates.  The
translation is faithful for every bit it reports, and it does not report the
ones this tree has no counterpart for:

  - `MANAGED_DICT` and `MANAGED_WEAKREF`.  The absence of managed dicts is
    itself recorded above; an instance dict here is an ordinary field, and
    saying otherwise would be a lie about the layout.
  - `MATCH_SELF`, `SEQUENCE` and `MAPPING`.  These drive `match` statement
    shortcuts in CPython's C code; the pattern machinery here reaches the
    same answers through the protocol rather than through a flag.
  - `HAVE_VECTORCALL` and `ITEMS_AT_END`, which describe CPython's call and
    allocation internals.
  - `DISALLOW_INSTANTIATION`, `METHOD_DESCRIPTOR` and `IS_ABSTRACT`.

`HAVE_GC` is reported and differs on a few builtins: `int`, `str`, `bytes` and
`float` are collector-tracked here and are not in CPython.  That is a real
difference in what the collector walks, not a translation gap.

A partial answer is a hazard -- code masking a bit that is not modelled reads
a confident zero -- and the alternative is not better: refusing to answer at
all breaks everything that asks about `BASETYPE` or a subclass bit, which is
what Python-level code actually reads.  `tests/test_type_flags.py` asserts the
bits that mean the same thing on both sides rather than the whole word, since
a test comparing values would be asserting this divergence rather than the
translation.

## A shake length is validated where CPython's OpenSSL wrapper is not

`_hashlib.HASHXOF.digest(n)` and `.hexdigest(n)` refuse a negative `n` with
`ValueError: value must be positive`, and refuse an `n` at or above `1 << 29`
with `ValueError: length is too large`.

CPython's own `_hashlib` checks neither.  Measured against 3.12:

```
>>> _hashlib.new('shake_128').digest(-1)
SystemError: Negative size passed to PyBytes_FromStringAndSize
>>> _hashlib.new('shake_128').digest(2**32)      # tries to allocate 4 GiB
```

Its *builtin* `_sha3` does check, and the two wordings above are that module's
own -- so this is not an invention, it is applying the builtin module's rule
to the OpenSSL one as well.  `1 << 29` is where CPython's `_sha3` draws the
line, measured exactly: `(1 << 29) - 1` is accepted and `1 << 29` is not.

Reproducing a `SystemError` would be reproducing a bug, and honouring a
four-gigabyte request from a single `digest()` call is worse than refusing it.
`tests/test_hashlib_openssl.py` therefore asserts only that the lengths ARE
refused, not how, because the alternative is comparing against a SystemError.

## `_hashlib` serves hashlib's fourteen names and no more

CPython's `_hashlib.openssl_md_meth_names` is everything the linked provider
offers -- 19 names on an ordinary OpenSSL 3, including `md4`, `ripemd160`,
`sm3` and `sha512_224`.  Ours is `hashlib.algorithms_guaranteed`: the same
fourteen, and nothing else.

So `hashlib.algorithms_available == hashlib.algorithms_guaranteed` here, where
in CPython the first is a superset.  Both satisfy what the documentation
promises -- `algorithms_available` is what this interpreter can serve -- and a
program that consults it, which is what it is for, gets a true answer either
way.  `_hashlib.new('ripemd160')` is a `ValueError` here rather than a digest.

The names reported ARE normalised, which is not optional: CPython's
`_hashopenssl` maps OpenSSL's spellings onto hashlib's, and `test_hashlib`
asserts `'blake2b512' not in hashlib.algorithms_available` and `'sha3-512' not
in` it either.  `blake2b` and `blake2s` are reported but get no
`openssl_blake2b`/`openssl_blake2s` constructor, exactly as in CPython:
`hashlib` routes both to `_blake2` unconditionally because OpenSSL's BLAKE2
supports neither keying nor the tree parameters, so an OpenSSL constructor for
them could only ever be reached by mistake.

## `hmac`'s OpenSSL fast path is chosen by name, not by callable type

`hmac.py` takes `_functype = type(_hashopenssl.openssl_sha256)` and then asks
`isinstance(digestmod, (str, _functype))` to decide whether to use the C HMAC.
In CPython that type is `builtin_function_or_method`; here `openssl_sha256` is
an ordinary Python function, so a caller's `digestmod=lambda: ...` passes the
same test and arrives at `_hashlib.hmac_new` too.

`hmac_new` and `hmac_digest` answer `UnsupportedDigestmodError` for any
`digestmod` that is neither a `str` nor one of our own `openssl_*` functions --
which is precisely the exception `hmac.py` catches, at its lines 61 and 199, to
fall back to its own Python implementation.  So the wrong path is entered and
then declined, and the observable behaviour is CPython's; what differs is
which of `hmac.py`'s two branches runs for a lambda.  This is the
single-builtin-callable-type divergence recorded above, reaching one more
module.

## `marshal.load()` reads the whole stream, not one object

CPython's `marshal.load()` pulls bytes from the file as the reader needs them,
so a file holding several marshalled objects is walked with one call per
object, and the file is left positioned after the one just read.  Ours calls
`file.read()` once and hands the whole result to the same reader `loads` uses.

For the only shape anybody writes -- a `.pyc`, or a file holding one object --
the two agree.  They differ for a file holding two: the second `load()` sees
an empty read and raises `EOFError`, and a file that is not seekable is
consumed whole rather than up to the object's end.

The reason is that the reader is written against a contiguous buffer with a
position in it (`marshal_buf`/`marshal_pos`/`marshal_len`), which is what a
`.pyc` already is.  Making it pull would mean an input abstraction under every
one of its read primitives, for a form of the call that nothing in the stdlib
makes.

`marshal.dumps()` also differs from CPython's byte for byte on values CPython
happens to hold more than one reference to: `FLAG_REF` is set from
`ob_refcnt > 1` there, so `marshal.dumps(0)` carries it in CPython and not
here.  Both are valid streams and each reads the other's; what is not stable
is the bytes.

## `sys.getsizeof()` reports the allocation, not CPython's number

`sys.getsizeof(1)` is 48 here and 28 in CPython; `sys.getsizeof('abc')` is 40
against 44.  The sizes are honest for this interpreter and simply describe a
different object: an int carries a compact `ival` and an `mpz_t` slot that is
only initialised on overflow, where CPython's is a variable-length digit array;
a str keeps UTF-8 with a byte length and a code-point length, where CPython's
keeps a latin-1/UCS-2/UCS-4 body with a different header.

`object.__sizeof__` answers `tp_basicsize` and each type that knows better
adds its own variable part, which is the shape CPython uses -- so the numbers
move correctly with the data even though they do not match.

What this costs is `test.support.check_sizeof`, which asserts exact figures:
those tests fail rather than crash, and they are measuring CPython's layout
rather than a property of the language.
