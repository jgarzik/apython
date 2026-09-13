# Known bugs

Open items only.  A bug that has been fixed belongs in the commit that fixed
it, not here; this file is the list of what is still wrong.

Every entry below was reproduced against the current build.  Each says what
the difference from CPython 3.12 is and, where it is known, why it is not a
one-line fix.

Divergences that are *deliberate* -- the `posix` subset, the absence of managed
dicts, a single-threaded `_thread`, the three recorded-oracle tests, and the
rest -- are not bugs and are not here.  They live in `DIVERGENCES.md`, with the
reasoning that chose them and what changing one would cost.

## Correctness

- **`pyexpat`'s `buffer_text` reads back `True` and does nothing.**  Setting
  it is accepted, the attribute answers `True`, and `CharacterDataHandler`
  still receives one call per fragment: `<a>hello &amp; goodbye world</a>`
  calls it three times -- `['hello ', '&', ' goodbye world']` -- where CPython
  coalesces them into one.  The buffer and `buffer_used` exist on the handle
  and `buffer_size` is validated and stored; what is missing is the
  accumulate-and-flush in `px_cb_chardata`, and the flush-before-every-other-
  callback that goes with it (the call sites are already in place, so the
  ORDER will be right when the body arrives).  Until then a caller has no way
  to detect the no-op, which is the shape
  [[half-implemented-is-worse]] is about.

- **Six of pyexpat's twenty-two handlers are stored, read back, and never
  fire.**  `DefaultHandler`, `DefaultHandlerExpand`, `NotStandaloneHandler`,
  `ExternalEntityRefHandler`, `EntityDeclHandler` and `ElementDeclHandler`
  have `dq 0, 0` rows in `px_installers`, so setting one registers the
  attribute and installs nothing.  Measured: `DefaultHandler`,
  `EntityDeclHandler` and `ElementDeclHandler` all fire in CPython over a
  document with an internal subset and none of them fire here.  `ElementDecl`
  is the one with real work behind it -- its `model` argument is a nested
  `(type, quant, name, children)` tuple walked out of libexpat's
  `XML_Content` tree, which must then be released with
  `XML_FreeContentModel` on every path including the raising ones.
  `xml.sax` is the one consumer still blocked, on `ExternalEntityRefHandler`
  plus `SetParamEntityParsing` and `ExternalEntityParserCreate`, which are
  also absent.

- **An internally raised `AttributeError` has no `.name` and no `.obj`.**
  CPython sets both on every attribute error it raises, and its "did you mean"
  machinery in `traceback` reads them; ours are absent entirely, so
  `getattr(e, 'name', None)` answers None where CPython answers the attribute.
  The keyword form -- `AttributeError("m", name=n, obj=o)` -- does work, and
  the family's refcounting is now correct, so what is missing is filling the
  two in at the raise sites.  `exc_from_cstr` is the wrong place for it: it is
  on the path of every internally raised exception, StopIteration from
  `call_iternext` included, and a `type_is_subtype` plus two `dict_set`s there
  would be paid by every `for` loop that ends.  The import machinery's own
  errors set theirs individually for exactly that reason, and attribute errors
  want the same treatment -- there are far more sites.

- **`cannot import name` never reports a circular import.**  CPython has a
  fourth wording for it, chosen by `__spec__._initializing`:
  `cannot import name 'X' from partially initialized module 'm' (most likely
  due to a circular import) (PATH)`.  Our modules carry `__spec__ = None` --
  nothing builds a ModuleSpec, because the import system is assembly rather
  than `importlib._bootstrap` -- so the condition cannot be asked.  Detecting
  it needs a during-body flag on the module object, which is a real change to
  module construction rather than a message fix.  The other three wordings,
  and `.name`/`.path`, match.

- **A relative import with no `__name__` in globals raises the wrong type.**
  `exec("from ... import x", {})` answers `ImportError: attempted relative
  import with no known parent package`; CPython answers
  `KeyError: "'__name__' not in globals"`, which falls out of
  `_calc___package__` doing `globals['__name__']` rather than being a message
  anyone chose.  CPython's own test suite does not test it, and ours is the
  more informative of the two, so this is recorded rather than matched.  Every
  other import-error shape measured -- missing module, missing submodule,
  not-a-package at any depth, a blocked None, and all three reachable
  `cannot import name` wordings -- now matches CPython exactly, attributes
  included.

- **Calls made with a misaligned stack, everywhere except the paths into
  GMP.**  The SysV ABI wants `rsp % 16 == 0` at a `call`, and glibc's float
  paths and GMP both use aligned SSE.  Every call into GMP is now made
  aligned, and `tests/gmp_align_probe.sh` is the gate: it breaks on every GMP
  call site in the built binary under gdb and reads rsp at each.  The
  same class is still there outside that reach, and three shapes of it are
  measured rather than guessed:

  `INT_NEED_MPZ` expands to `push rdi` / `call int_promote_mpz` / `pop rdi`,
  so every one of its expansions calls at the wrong parity -- all 1,261 in a
  bignum workload.  It is harmless today only because `int_promote_mpz` saves
  rsp and `and`s it, which is the reason its own GMP call never showed.

  `V_PACK`'s cold path is called AFTER `leave` in every function that packs
  its return value on the way out, so it runs at the caller's parity rather
  than the function's -- eight bytes out.

  And the propagation: `obj_richcompare_bool` is entered misaligned by
  `dict_lookup`, which is entered misaligned by `dict_set` and by a dozen
  module-init callers, and everything under any of them inherits it.

  Neither `lint.py` nor any other source-level check can find these.
  `check_alignment` counts only the pushes before the first non-push
  instruction, exempts `DEF_FUNC_BARE` entirely, and cannot see inside a NASM
  macro -- which hides both pushes and branches.  A source-level detector
  written for exactly this produced twenty-two false positives and was thrown
  away.  What works is a CFG walk over the DISASSEMBLY, tracking rsp's offset
  from entry: objdump sees the macros expanded.  The one thing such a walk
  needs told is entry parity, because an opcode handler is reached by `jmp`
  from the dispatch table and is entered at the opposite parity from a
  function reached by `call` -- assume the wrong one and every handler in the
  tree reports as broken.

- **`except*` does not look inside a NESTED group, and a group publishes
  neither `split` nor `subgroup` nor `derive`.**  `except* KeyError` over
  `ExceptionGroup("outer", [ExceptionGroup("inner", [KeyError()]), OSError()])`
  matches the OSError and leaves the outer group unhandled, where CPython
  recurses and matches the KeyError through the nesting.  The split is
  `eg_split`, and it walks one level.

  The three methods are the other half of the same gap: the splitting exists
  only as the thing `except*` calls, so a program cannot do it itself.  And
  where CPython's `split` asks the group to `derive()` a new one -- whose
  default builds a plain `ExceptionGroup` -- `eg_split` constructs one of the
  group's OWN type, so a subclass of `ExceptionGroup` splits into more of
  itself rather than into `ExceptionGroup`.  Publishing the three and routing
  the internal split through `derive` is one change, because the type the
  halves get is decided there.

- **A dunder's RESULT is not type-checked except for `__str__`, `__repr__` and
  `__format__`.**  Those three are refused now, because a non-str reaching an
  f-string or a container repr is a segfault rather than a wrong answer.  The
  rest differ only in WORDING, and each says less than CPython's does:
  `__bool__ should return bool` where CPython adds `, returned tuple`;
  `'str' object cannot be interpreted as an integer` for a `__hash__` where
  CPython says `__hash__ method should return an integer`; `__int__ returned
  non-int` and `__index__ returned non-int` without the `(type str)` CPython
  appends; and `float()` reports its ARGUMENT's type rather than
  `C.__float__ returned non-float (type str)`.

- **A dunder whose value is not callable at all reports the wrong thing, and
  an immediate reports nothing.**  `type("C", (), {"__len__": 5})` then
  `len(c)` is `RuntimeError: slot wrapper failed without an exception` where
  CPython says `TypeError: 'int' object is not callable`, and the same with a
  float.  A POINTER that is not callable -- `None`, `True`, `"x"` -- is
  reported correctly, so what differs is only the int and float immediates:
  the slot wrapper's failure arm asks the value for a type it has no header
  to answer from, and returns without setting an exception.  `__next__` is
  the one that answers WRONGLY rather than confusingly:
  `type("C", (), {"__next__": 5})` makes `next(c)` a clean StopIteration, so
  a `for` over it is empty where CPython raises.  Found while fixing
  `dunder_bind`'s third arm and confirmed to pre-date it -- the behaviour is
  identical on a binary built before that change.

- **A plain builtin function stored in a class body is BOUND.**  CPython has
  three types where this tree has one: `builtin_function_or_method`, which has
  no `tp_descr_get` and therefore does not bind, and `method_descriptor` and
  `wrapper_descriptor`, which do.  So `class C: f = len` gives `C().f` a bound
  method here and the bare function there, and `C().f([1,2,3])` is
  "len() takes exactly one argument (2 given)".  `hasattr(len, '__get__')` is
  True for the same reason and False in CPython.

  The field that would tell them apart is `PyBuiltinObject.func_kind`, and it
  cannot: `builtin_func_new` makes everything BUILTIN_KIND_FUNCTION, and only
  `type_stamp_methods` upgrades it -- which runs over the tables `methods/init*.asm`
  builds and not over the ones `io.asm`, `socket.asm`, `array.asm`,
  `posixdir.asm` and `abcmod.asm` build for themselves.  Binding on the kind
  was tried and unbinds every method in those modules.  Nor can the stamping
  simply be extended to every type: it MUTATES the builtin object, so stamping
  a user class's dict would give the process-wide `len` a `func_owner` of that
  class.  Closing it means a second type, or a per-object flag set where the
  builtin is created rather than where it is registered.

- **`print` to a broken pipe reports nothing.**  SIGPIPE is ignored now, so
  the process survives and `os.write`/`file.write` raise BrokenPipeError --
  but `print` itself answers None and the output is silently lost, where
  CPython raises.  `apython foo.py | head` exits 0 with the tail of its output
  discarded.  The write it makes does not check its result.

- **A class's `__dict__` is short of `__dict__`, `__doc__` and
  `__weakref__`.**  `sorted(C.__dict__)` for a plain class is
  `['__module__']` here and `['__dict__', '__doc__', '__module__',
  '__weakref__']` in CPython.  `__qualname__` was a fourth difference in the
  other direction and is fixed; these three are entries type_new adds that
  type_from_parts does not.  Anything that walks a class's own dict and
  expects the descriptors -- `inspect.getattr_static`, `__slots__` validation,
  pickling by reference -- sees a shorter one.

- **A struct-sequence type can be subclassed.**  `class X(os.stat_result)`
  builds a class here and is `TypeError: type 'os.stat_result' is not an
  acceptable base type` in CPython: those types do not carry
  TYPE_FLAG_BASETYPE and nothing tests it.  The subclass has no descriptor
  word of its own, so the struct-sequence accessors read past its allocation.
  The general check -- refuse a base without TYPE_FLAG_BASETYPE -- wants
  auditing across every builtin type first, because a flag missing by accident
  would start refusing subclasses that work today.

- **`random.randbytes` is seconds per megabyte**, where CPython's is instant:
  `_random` is Python here and CPython's is C.  2.4 s/MiB through this tree's
  own `lib/random.py`, and 35 s/MiB through CPython's `Lib/random.py`, which
  is what a test run with its stdlib on the path gets.  That is the whole of
  why `test_zlib` times out -- `check_big_compress_buffer` opens with
  `random.randbytes(10 * 1024 * 1024)`, and CPython's `bigmemtest` runs it
  even without `-M` (at a small size, but the ten megabytes are generated
  regardless).  Nothing is wrong; it is slow.  `test_zipfile64` is the same
  shape, one order of magnitude larger.

- **`test_sys_settrace`'s `test_jump_extended_args_for_iter` hangs.**  The
  compile is fast -- a hundred thousand lines in 0.8s -- so it is the trace
  machinery under `sys.settrace` and a jump, not the compiler.  It sits with
  the rest of the settrace divergence below.

- **`super(C, obj)` on a PROXY answers differently depending on what comes
  after it in the file.**  CPython's supercheck asks an object what class it
  says it is when neither its type nor the object itself is a subtype, which
  is what makes super() work through a proxy that forwards attribute access --
  `test_descr.test_proxy_super` is exactly that.  It works on its own; in a
  longer program the same call refuses with "obj must be an instance or
  subtype of type", and DELETING an unrelated statement that comes AFTER it
  makes it work again.

  valgrind is clean over both, so it is not memory corruption: it is
  `obj_declared_class` answering 0, which means the `__class__` lookup did not
  produce the class.  That lookup runs the proxy's own `__getattribute__` --
  Python, from inside an opcode handler, which is the one thing this path does
  that no other form of super() does, and it recurses once more because
  `self.__obj` goes through `__getattribute__` too.  Something about that
  nested eval, and not about the object, decides the answer.

  `tests/test_super_bad_object.py` covers the refusals and leaves the proxy
  out for this reason; the shape that fails is the file that test was cut
  down from, with the proxy call followed by two more statements.

- **`scandir()` on a BYTES path yields str entries.**  CPython gives a bytes
  path bytes names and bytes paths back; here the argument goes through
  `posix_path_arg`, which hands over a C string, and the entries are built
  from it as str.  Everything works, and works on the right files -- what
  differs is the type of `.name` and `.path`, which `os.walk(b'.')` and the
  bytes half of `glob` then propagate.  Fixing it means carrying the
  argument's own kind through the getdents64 loop and building bytes objects
  on that side, which is the second half of every string-building step in
  `posix_scandir`.

- **A raise from a C-level slot is a non-local jump, so a C caller cannot
  absorb it.**  `slot_mp_subscript` and its siblings end in `slot_reraise`,
  which tail-jumps into `eval_exception_unwind`; a builtin's own miss --
  `dict_subscript`'s KeyError, say -- goes through `RAISE`, which does the
  same.  Neither returns to its caller, so an opcode that wants to try a
  lookup and recover from the miss cannot go through the slot at all.

  `mapping_getitem_opt` is the way round it for a heaptype (ask
  `__getitem__` through `dunder_call_2`, which does return), and LOAD_NAME
  and SETUP_ANNOTATIONS use it for a locals mapping that is not a dict.  It
  does not help for a builtin `__getitem__`, so a dict SUBCLASS keeps the
  direct table read in LOAD_NAME where CPython's `PyDict_CheckExact` sends it
  through `PyObject_GetItem`: an overridden `__getitem__` on a dict subclass
  used as `exec()` locals is not consulted.  Fixing it properly means the
  builtin subscripts reporting a miss by RETURNING rather than by raising,
  which is every caller of `dict_subscript`.

- **OSError's four named attributes are in its instance `__dict__`.**
  `errno`, `strerror`, `filename` and `filename2` are C fields in CPython and
  do not appear in `vars(e)`; here `exc_oserror` writes them into `exc_dict`,
  so `OSError(2, 'x').__dict__` has four entries CPython's has none of.  Every
  read of them agrees, and so does `args`; what differs is only what
  `__dict__`, `vars()` and `__getstate__` report.  Moving them means four more
  fields on PyExceptionObject and a getattr arm for each, which is what
  CPython does.

- **The attribute lookup order is instance-dict-first unless the MRO holds a
  data descriptor**, which is observable when user code mutates the class
  DURING the lookup.  CPython always consults the type first and keeps what it
  found; this consults the instance dict first when
  TYPE_FLAG_MRO_HAS_DATA_DESCR is clear, which is almost every class, because
  that is the fast order for an ordinary `self.x`.

  A key whose `__eq__` runs `del C.meth` while the instance dict is being
  probed therefore makes `d.meth` an AttributeError here and a bound method in
  CPython.  Nothing is unsafe -- the descriptor the MRO walk found is held
  across the probe now -- and no ordinary program can tell the two orders
  apart.  Closing it means paying the MRO walk on every attribute access, or
  finding a cheaper way to notice that the class changed underneath.

- **A user `__eq__` that reaches itself answers False instead of raising
  RecursionError.**  `class D: def __eq__(s, o): return s.me == o.me` with
  `p.me = p` gives False here and RecursionError in CPython.  The container
  comparisons are guarded (`C_RECURSION_ENTER` in list, tuple and dict) and
  Python-level recursion is guarded by `recursion_depth`, so something on the
  instance-comparison path is deciding the answer before either limit is
  reached rather than recursing; which one has not been traced.

- **`f(*5)` does not name the callable.**  CPython says
  "__main__.f() argument after * must be an iterable, not int"; this says
  "Value after * must be an iterable, not int", which is CPython's message
  for the OTHER shape -- `f(*a, *b)` and `[*5]`.  The two differ because
  CPython compiles a lone `*x` to a bare CALL_FUNCTION_EX and this compiles
  it to BUILD_LIST + LIST_EXTEND, so the refusal comes from a different
  opcode.  Matching it means matching the codegen, and then teaching
  CALL_FUNCTION_EX to materialise an arbitrary iterable -- it takes a tuple
  or a list today.  The `**` half is done: DICT_MERGE names the callable and
  accepts any mapping.

- **`bytes(obj)` does not take an `__index__`-only object as a count.**
  `bytes(C())` where `C.__index__` returns 3 is three zero bytes in CPython --
  its `PyIndex_Check` arm runs before the buffer and the iterable -- and
  "cannot convert 'C' object to bytes" here: `byteslike_source`'s count arm
  takes an int, an int subclass and bool by name.  `__bytes__` is consulted
  now and wins over `__index__` as it should, so only the object whose ONLY
  numeric face is `__index__` differs.  Closing it means asking the type for
  `__index__` where the int check is, which puts a dunder lookup on the path
  of every `bytes(x)` whose argument is not one of the four named types.

- **A generator expression containing an async comprehension is not itself an
  async generator.**  `([i async for i in x] for x in y)` is an
  `async_generator` in CPython and a plain `generator` when our own compiler
  builds it -- a `.pyc` gets it right, because the flag comes from the
  marshalled code object.  The nested comprehension marks its OWN scope
  SCF_COROUTINE and nothing propagates that to the genexp around it; CPython's
  symtable does.  The refusals and acceptances all match
  (`tests/test_compile_async_scope.py`); only the kind of object is wrong, and
  it makes `async for lst in that_genexp` a TypeError.

- **Source that is not valid UTF-8 is refused with our own wording, and one
  column off for a bad four-byte lead.**  CPython reports a codec error --
  `(unicode error) 'utf-8' codec can't decode byte 0xe9 in position 3:
  unexpected end of data` -- with a position of its own; `src/compiler/lex.asm`
  says `invalid non-UTF-8 byte 0xe9` at the byte's own column.  The accept /
  reject decision and the LINE match on eleven shapes
  (`tests/test_compile_utf8_source.py`), and bytes inside a comment are
  accepted by both.

- **Three messages that name no type.**  `b"x" in ValueError()` is
  "argument of type is not iterable" where CPython says "argument of type
  'ValueError' is not iterable"; `async with` over an object with no
  `__aexit__` is "'async with' requires __aexit__ method" where CPython names
  the object and distinguishes "no `__aenter__` either" from "only
  `__aexit__` missing" -- `op_before_with` does both and its async twin does
  not; and `__bytes__` returning a non-bytes omits CPython's `(type int)`
  suffix.  The first attempt at the async one got the operand cleanup wrong
  and segfaulted: that path releases nothing and lets the unwinder take the
  manager out of the value-stack slot, which is what any rewrite has to keep.

- **A `bytes` SUBCLASS from `__bytes__` is refused, and `C(x)` for a bytes
  subclass answers a plain bytes.**  The check is `ob_type == bytes_type`
  where CPython uses `PyBytes_Check`, which takes a subclass; and
  `bytes_type_call` hands back the dunder's own object without asking the
  subclass to adopt it.

- **`co_freevars` is in source order and CPython's is sorted**, and a module
  code object reports its globals in `co_varnames`.  The first is the order
  our symbol table appends free variables in; the second is that a module
  scope puts its names in `Scope.varnames` at all, where CPython gives a
  module body no fast locals. `co_varnames`, `co_cellvars`, `co_freevars` and
  `co_nlocals` agree with CPython for every function shape tested
  (`tests/test_code_localsplus.py`); these two are what is left.

- **PEP 3131's NFKC normalisation of identifiers is absent.**  `class T: µ = 1`
  then `T.µ` works and `T.μ` is an AttributeError: CPython normalises every
  identifier to NFKC, so the MICRO SIGN U+00B5 and GREEK SMALL LETTER MU
  U+03BC are the same name there and two names here.  The XID_Start /
  XID_Continue half of the rule is checked now (`src/compiler/lex.asm`, over
  the flags `gen_unicodecase.py` emits), which is what stopped an invisible
  NBSP from being a variable; normalisation is the other half and wants the
  decomposition and composition tables, which are a generated artefact an
  order of magnitude larger than the case mappings.  It is the one thing
  CPython's `test_unicode_identifiers` still fails on.

- **Seven syntax errors differ from CPython in a POSITION rather than in the
  message**, recorded in `tests/syntax_floor.txt` as differing and shown by
  `bash tests/syntax_probe.sh --show`:

  `no binding for nonlocal 'x' found` reports line 0.  It is raised by the
  analyze pass, which holds a scope but no node -- `comp_error_node` needs
  one -- and closing it means recording the declaring node per NAME, because
  a scope may have several `nonlocal` statements and the message is about one
  of them.  Every other symbol-table and codegen error carries its real line
  now.

  A mapping pattern's non-literal key differs in wording as well as span:
  `case {q: w}` is "invalid syntax" in CPython, which rejects it in the
  grammar, and "a mapping pattern's keys must be literals" here, from the
  pattern compiler.

  The other five are columns: an unexpected indent and an unindent that
  matches no outer level (CPython blames the first non-space character and
  runs the span off the line), the bare `*` in `def f(*)`, the location of a
  missing indented block after a header that ends in whitespace, and the
  column of `unexpected character after line continuation character`.

- **An f-string's field errors differ in wording**, though both interpreters
  raise a SyntaxError: `f'{3!g}'` is "f-string: invalid conversion character
  'g': expected 's', 'r', or 'a'" in CPython and "f-string: invalid
  conversion, expected 's', 'r' or 'a'" here, and `f'{}'` is "f-string: valid
  expression required before '}'" there against whatever the empty span makes
  the expression parser say here.  `src/compiler/fstring.asm` has two
  messages where CPython has a dozen, and they are reported at the whole
  f-string token rather than inside the field.  That is most of what
  CPython's `test_fstring` still counts: the rejection is right and the
  sentence is not.

- **`super(C, obj)` reaches its own four attributes through the opcode now,
  but our compiler emits LOAD_SUPER_ATTR where CPython's does not.**  CPython
  only specialises `super(...).attr` inside a function; at module level it
  compiles an ordinary call and a LOAD_ATTR.  The two paths answer the same
  thing for every shape tested, so nothing is observably wrong -- but there
  are two paths where CPython has one, and the opcode's is the one with
  arms of its own.

- **Missing C modules.**  The ranking here is by what actually stands in the
  way rather than by which import fails first -- the two are not the same,
  and `_imp` was reached by twelve modules a few lines after some other
  import that looked like the blocker.  `_imp`, `marshal`, `_warnings`,
  `_typing`, the `_sha*`/`_md5` family and `_posixsubprocess` are there now,
  and `importlib`, `hashlib`, `random` and `subprocess` with them.  So is
  `_signal`, with delivery at the top of a loop the way CPython's is, and
  `doctest`, `pdb`, `unittest` and `signal` with it.  So is `zlib`, as a shim
  over `-lz` on the precedent `-lgmp` set, and `gzip` with it -- and
  `zipfile`, `tarfile` and `shutil`, which imported before and could not
  compress.  So is `array`, which was the largest of these by reach.  What
  is left is genuinely C: `unicodedata`, `_tracemalloc`, `_symtable`, `_ssl`,
  `_sqlite3`, `_crypt`, `_lzma`, `_bz2`, `_ctypes`, `_curses`, `pyexpat` and
  `_tkinter`.
  (`_io` is not among them: `src/modules/io.asm` supplies `_iocore` and
  `lib/_io.py` assembles both halves under the name `_io`.  `_socket` and
  `select` are the same split over `_socketcore`.  Neither are `math`,
  `_collections`, `_struct`, `_random`, `_contextvars`, `_string`,
  `_tokenize`, `_operator`, `binascii`, `atexit` and `_ast`, which are
  there, and so are `_csv` and `termios` -- the second over one raw
  `posix.ioctl`, the same split `_socket` and `select` use.)
  `make check-stdlib` gives the current figure.

  `array` is done, and it is the reason the old "one or two modules apiece"
  reading of this list was wrong: it was what stood between this tree and
  `multiprocessing`, and CPython's own suite imports it from the test modules
  for `struct`, `memoryview`, `io`, `bytes`, `socket`, `re`, `marshal`,
  `codecs` and the compression family.  What is left out is that `L` and `Q`
  hold what an int64 holds rather than a uint64, because `obj_as_index`
  refuses anything wider.

  `math`'s `gamma`, `lgamma`, the n-ary `hypot` and `sumprod` round
  differently from CPython's, which uses its own Lanczos approximation and
  double-double arithmetic where these use glibc and a Neumaier sum.  `dist`
  shares `hypot`'s routine and so shares the note.  `fsum` is exact: it is
  Shewchuk's algorithm, as CPython's is.  `tests/test_math.py` says which is
  which.

- **`str.find` and `str.count` are the naive O(n*m) search.**  CPython's is
  Crochemore-Perrin two-way with a Bloom-filter skip, which is O(n + m), and
  its own test says so: `string_tests.test_adaptive_find` searches a
  1,000,000-character haystack built to defeat the naive scan, and
  test_userstring and test_string time out on it here rather than failing.
  Ordinary searches are unaffected -- the shapes that hurt are the ones with
  long repeated prefixes.

- **Indexing a non-ASCII string is O(n), so a loop over one is quadratic.**
  `str_cp_offset` and `str_byte_to_cp` walk from byte 0 every time, because
  nothing remembers where the last code point was.  `s[i]` in a loop, a slice
  of a wide string and `str.find`'s conversion of its answer back to a code
  point index all pay it; CPython's strings are fixed-width per object and pay
  nothing.  `tests/run_str_bench.sh` runs its wide indexing and slicing cases
  at 50-100x fewer iterations than their ASCII partners for this reason alone,
  which is why those rows cannot be compared with the rest of the suite.

  The walk itself is as cheap as it can be made -- the per-code-point call was
  inlined and cost 20% of the instructions of a wide indexing loop -- but the
  shape is what is wrong.  What closes it is a cursor on the string object:
  one word holding the last (code point index, byte offset) pair, which makes
  forward sequential indexing O(1) amortised.  A zeroed cursor is valid for
  every string, so it needs no invalidation and strings are immutable in any
  case.  It is not done here because it moves `PyStrObject.data` and every one
  of the twenty-odd places that build a string by hand has to initialise the
  new field -- and a missed one is a wrong CHARACTER out of a wide string, in
  a path the suite barely exercises, rather than a crash.

- **One call inside an opcode handler is made with `rsp` misaligned.**
  Recorded in `tests/align_floor.txt`, which `lint.py` ratchets: a new one
  fails the build and the set can only shrink.

  They are not cosmetic, and they are not local.  A misaligned call
  PROPAGATES: the callee's whole frame is 8 out, so every Python frame the
  interpreter runs beneath it is too.  The fault surfaces far away and only
  when something eventually reaches an aligned SSE store -- which is how this
  was found at all: `import gzip; gzip.open(...)` faulted inside libz's
  `inflate`, at a `movaps %xmm0,-0x70(%rbp)`, several thousand instructions
  from anything zlib had done wrong.

  Forty-two of the forty-three are paid.  Most were a loop index or an item
  saved across a call with a lone push; those became frame slots rather than
  pads, because a handler with calls at both push depths has no single frame
  size that satisfies them all -- and the pushed value always had a name.

  The one left is `op_set_update`'s `call set_add`, which lint reports at a
  depth eight above what its own pushes and frame account for.  I could not
  source the difference, and moving the frame by eight only moves which call
  in that handler is wrong.  Changing the code to satisfy a number I do not
  understand is worse than leaving it recorded.

- **Functions with no docblock at all**, and, among those that have one,
  docblocks with no `->` signature line.  The signature is the only part of a
  function's contract that nothing checks, so its absence is a real gap rather
  than a cosmetic one.  This is the one item here a script cannot finish:
  writing a signature means reading what the function actually returns.  It is
  measured now rather than estimated -- `tests/docblock_floor.txt` holds the
  count per file and `lint.py`'s `check_docblocks` fails when one goes above
  it, so what is left can only shrink.
