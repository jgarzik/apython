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

- **`pdb` blocks at its prompt when stdin is a pipe rather than a terminal.**
  Three lines reproduce it:

      printf 'raise ValueError("boom")\n' > r.py
      printf 'c\nq\n' | ./apython -m pdb r.py      # never returns

  CPython exits 0.  It is not `input()` -- `input()` at EOF raises EOFError
  here, after prior reads as well -- and it is not `-m`: driving `pdb.main()`
  from `-c` blocks identically.  The process sits in `pipe_read` with no CPU,
  so it is a read that never sees the data or the EOF, somewhere in pdb's
  restart/post-mortem path; `apython -m pdb` on a script that does NOT raise
  consumes several commands first and blocks later.
  It is what makes CPython's `test_pdb` a HANG rather than a row of failures.

  Worth knowing: it was unreachable until `open()` learned to accept a str
  SUBCLASS, because pdb's own `_ScriptTarget` is one and every script died on
  the TypeError before pdb could run it.  The module scored 13 of 87 then and
  0 now -- the arithmetic is worse, the interpreter is not.

- **`sys.stdout`'s repr is `<stdout>`, where CPython's is
  `<_io.TextIOWrapper name='<stdout>' mode='w' encoding='utf-8'>`.**  Visible
  wherever an unraisable report names the stream -- the "Exception ignored in:"
  line a failed exit-time flush prints.  The exception line under it matches
  exactly, and so does the exit code; only the object's own repr differs,
  because the start-up streams are a `file_type` here rather than a Python
  wrapper over a FileIO.

- **`frame.f_lineno` cannot be assigned, so `pdb`'s `jump` does not work.**
  `frameobj_setattr` refuses it outright: moving the instruction pointer to
  the start of another line means re-deriving the block stack for the
  destination, and refusing is CPython's own answer for a jump it cannot make.
  Every other `frame` attribute is writable or readable as CPython has it.

  What that costs is most of `test_sys_settrace`.  Its `JumpTestCase` is a
  hundred and one tests, all of which jump; the refusal makes them fail, and
  two of them then do not terminate --
  `test_no_jump_infinite_while_loop` jumps OUT of a `while True:` that appends
  to a list, so without the jump the loop runs until the allocator gives up
  and the module dies with "Fatal: out of memory" before it can report.

  Closing it is CPython's `frame_setlineno`, and it is a project rather than a
  patch: `marklines` over the line table to find which instructions start a
  line, `first_line_not_before` to pick the destination, and `mark_stacks` --
  an abstract interpretation over the whole bytecode that propagates an
  encoded block stack to a fixpoint, seeding every exception-table handler --
  so that `compatible_stack` can refuse a jump into a `for` body or an
  `except` block with the sentence CPython uses.

  The module used to TIME OUT rather than fail, with 18 of its tests run, and
  that was a different bug: `co_lines()` and `co_positions()` were quadratic
  in a code object's length and unittest formats a traceback through the
  second.  That is fixed; 84 tests run now.

- **A raise from a C-level slot is a non-local jump, so a C caller cannot
  absorb it.**  `slot_mp_subscript` and its siblings end in `slot_reraise`,
  which tail-jumps into `eval_exception_unwind`; a builtin's own miss --
  `dict_subscript`'s KeyError, say -- goes through `RAISE`, which does the
  same.  Neither returns to its caller, so an opcode that wants to try a
  lookup and recover from the miss cannot go through the slot at all.

  It also LEAKS.  `type_call` holds the new instance in a register across the
  `__init__` call, and a builtin `__init__` that refuses its arguments raises
  from inside itself -- so the instance is never released.  Measured at about
  128 bytes per refusal, the same for every shape: `_io.FileIO("/no/such")`,
  `_io.FileIO()` with no arguments, `_io.FileIO(path, "zz")` and
  `_io.BytesIO(5.5)` all leak identically, while a Python `__init__` that
  raises leaks nothing, because that one RETURNS with the exception set.  So
  it is general to every builtin `__init__` registered in a type's dict, and
  the fix is the same one this entry already names rather than anything local
  to `_io`.

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
  read of them agrees, `args` agrees, and `__reduce__` agrees -- OSError has
  one of its own now, which re-packs the filename into the arguments and
  strips the four names out of the state, so a pickle and a deepcopy of every
  shape round-trip identically.  What is LEFT is what `__dict__`, `vars()` and
  `__getstate__` report.  Closing it means four more fields on
  PyExceptionObject, a getattr and a setattr arm for each, and a positive
  marker -- a type flag, not a `tp_basicsize` comparison, because a
  `__slots__` subclass of any other exception has a larger basicsize too and
  those words are its slots.

- **`bytes` has no `__new__`, so a bytes SUBCLASS cannot be reconstructed.**
  Every other variable-size builtin publishes one -- `str` and `tuple` do --
  and `bytes_type.tp_new` is 0 with nothing in its `tp_dict`, so
  `B.__new__` resolves along the MRO to `object.__new__`, which refuses a
  variable-size type: `object.__new__(B) is not safe, use B.__new__()`.
  `copy.copy` and `copy.deepcopy` of a bytes subclass both end there, and so
  would a pickle.  `bytes.__getnewargs__` is in place, so the arguments are
  ready for the day the constructor is; what is missing is the constructor,
  which has to allocate the subclass's own `tp_basicsize` plus the data and
  then copy it inline, the way `instance_alloc` does for a str subclass.
  `bytearray` is not affected -- its data is out of line and it has a
  constructor of its own.

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

- **Source that is not valid UTF-8 is refused with our own wording, and one
  column off for a bad four-byte lead.**  CPython reports a codec error --
  `(unicode error) 'utf-8' codec can't decode byte 0xe9 in position 3:
  unexpected end of data` -- with a position of its own; `src/compiler/lex.asm`
  says `invalid non-UTF-8 byte 0xe9` at the byte's own column.  The accept /
  reject decision and the LINE match on eleven shapes
  (`tests/test_compile_utf8_source.py`), and bytes inside a comment are
  accepted by both.

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
  is left is genuinely C: `_tracemalloc`, `_symtable`, `_ssl`,
  `_sqlite3`, `_crypt`, `_ctypes`, `_curses` and `_tkinter`.  `fcntl`,
  `resource`, `syslog`, `pwd`, `grp`, `audioop` and `_lsprof` are there now
  and none of them needed much: two descriptor calls in `posixfd.asm`, two
  resource calls in `posixproc.asm`, and Python for the rest -- `syslog` over
  a datagram socket rather than over libc's wrapper for it, `_lsprof` over
  `sys.setprofile`, `pwd` and `grp` over the files rather than over NSS
  (DIVERGENCES.md carries what that costs).  `_lzma` and
  `_bz2` are there now, each a shim over its library the way `zlib` is, and
  `lzma`, `bz2` and the compression halves of `tarfile` and `zipfile` with
  them.  `_multibytecodec` and the six CJK codec modules are deliberately
  deferred and are in DIVERGENCES.md rather than here.

  `unicodedata` is there now, over tables generated from a running CPython the
  way `\N{...}`'s names and the case mappings already were, and so are
  `normalize()` and `decomposition()`: `src/modules/unicodenorm.asm` over
  `unicodenorm_tables.asm`, verified byte for byte against CPython's own
  answers for every code point and for 120,000 random sequences.  **`ucd_3_2_0`** is there
  too -- the frozen Unicode 3.2 copy RFC 3454 is written against, which
  `stringprep` imports -- as `src/modules/ucd32.asm` over
  `ucd32_tables.asm`: the same engine pointed at a second table set, with the
  five decompositions Corrigendum #4 corrected kept at their pre-corrigendum
  values, because that is what a frozen database means and what CPython's own
  copy answers.  Its `lookup`, `name` and the numeric values are not there:
  nothing asks the 3.2 database for them, and each would be a second copy of a
  table larger than all the rest together.
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

  `cmath` is there now, and it is C99's complex functions reached directly --
  a `double complex` is two SSE eightbytes under the SysV ABI, which is
  exactly how a PyComplexObject's two doubles already arrive and leave.  So
  its branch cuts are libm's, where CPython's are its own: the two agree on
  every cut and on every error, and differ in the last ulp or two on ordinary
  values, which is what `tests/test_cmath.py` compares to twelve digits rather
  than seventeen.  Two of CPython's own `test_cmath` checks still fail on
  that: one signed zero and one nan, both from `test_specific_values`.  `e`,
  the half-float, is the one native `memoryview.cast()` format in the same
  position.

  `math`'s `gamma`, `lgamma` and the n-ary `hypot` round differently from
  CPython's, which uses its own Lanczos approximation and Veltkamp-Dekker
  splitting where these use glibc and a Neumaier sum.  `dist`
  shares `hypot`'s routine and so shares the note.  `fsum` is exact: it is
  Shewchuk's algorithm, as CPython's is.  `tests/test_math.py` says which is
  which.

- **`rfind` and `rindex` are still the naive backward scan.**  The forward
  direction is Crochemore-Perrin two-way now -- `ap_memfind` counts the
  candidates its memchr scan rejects and switches once that work would exceed
  the haystack's own length -- so `find`, `count`, `index` and `in` are
  O(n + m) for str, bytes and bytearray alike.  `ap_memrfind` walks down one
  position at a time and is O(n*m) on the same shapes; CPython runs the
  two-way search over the reversed strings for it.  Nothing in CPython's own
  suite measures that direction, which is why it is recorded rather than
  written.

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
