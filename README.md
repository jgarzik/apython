# apython

A Python 3.12 bytecode interpreter and source compiler written in x86-64 NASM
assembly for Linux, exploring fast single-core Python execution—with a focus on
floating-point and integer performance—without a JIT.

## Table of Contents

- [Why apython?](#why-apython)
- [Key Highlights](#key-highlights)
- [AI LLM Level](#ai-llm-level)
- [Quick Start](#quick-start)
  - [Dependencies](#dependencies)
  - [Build and Run](#build-and-run)
  - [Install](#install)
- [Testing](#testing)
- [Debugging](#debugging)
- [Documentation](#documentation)
- [License](#license)

## Why apython?

apython compiles and executes Python 3.12 directly on Linux x86-64: it reads
`.py` source through an in-tree compiler written in x86-64 assembly, runs
CPython `.pyc` bytecode directly through a native marshal reader, and ships
CPython 3.12's own unmodified standard library (`stdlib/`).

There is no CPython runtime, no JIT, and no C-level interpreter wrapper. From
the bytecode dispatch loop and NaN-boxed value representation to the type
system, cycle-collecting garbage collector, regex engine, and `io_uring`/epoll
async event loop, the interpreter is built directly in assembly to eliminate
interpreter overhead and keep hot paths tight on x86-64 hardware.

On current measurements, apython runs roughly **1.4x–1.5x faster than CPython
3.12** on macro and core benchmarks (up to **~1.8x–2.1x** on integer and
floating-point suites) and passes over **70%** of CPython 3.12's matched test
suite without crashing. See [ROADMAP.md](ROADMAP.md) for live numbers,
per-suite breakdowns, and remaining gaps.

## Key Highlights

- **NaN-boxed 64-bit values** ([valuebox.md](valuebox.md)) — one machine word
  per Python value. Heap pointers are stored raw (zero-cost dereference),
  floats are offset-encoded into NaN space, and integers in `[-2^50, 2^50)` are
  unboxed immediates with no heap allocation or refcounting. Larger integers
  promote automatically to GMP (`libgmp`).
- **Direct-threaded bytecode VM** — 256-entry BTB-friendly jump table with
  guarded inline specializations for arithmetic, comparisons, iteration,
  attribute lookup, and global loads, backed by a custom size-class pool
  allocator.
- **Self-hosted assembly Python 3.12 compiler** — table-driven tokenizer, Pratt
  parser, symbol table, code generator, and assembler driving `./apython
  script.py`, `compile()`, `eval()`, `exec()`, and source imports (including
  PEP 701 f-strings, structural pattern matching, `except*`, and PEP 695
  syntax).
- **Vendored CPython 3.12 standard library** — runs CPython's unmodified
  `Lib/` (`stdlib/`), paired with native assembly builtin modules
  (`src/modules/`) and thin Python stand-ins (`lib/`) over system libraries
  for TLS/crypto, compression, XML, SQLite, and FFI (`ctypes`).
- **Reference counting + 3-generation cycle GC** — deterministic deallocation
  with generational cycle collection across containers, classes, frames,
  generators, and closures.
- **Native `io_uring` / `epoll` async I/O** — pure-assembly `asyncio` event
  loop and TCP streams, with direct Linux syscalls for core I/O paths.
- **DWARF debug symbols** — full GDB support with frame-pointer unwinding,
  function boundaries, and `.asm` source-level stepping.

## AI LLM Level

apython is expert-guided, AI-written. An expert makes the top-level data
structure, data flow, and code algorithm choices, not a "dumb ralph wiggum w/
cpython oracle" approach. Basing a project entirely in x86-64 assembly would
not have been feasible for one person without an LLM.

## Quick Start

apython targets **Linux x86-64**.

### Dependencies

On Debian/Ubuntu:

```bash
sudo apt-get update
sudo apt-get install -y nasm gcc libgmp-dev zlib1g-dev libbz2-dev \
  liblzma-dev libssl-dev libexpat1-dev libffi-dev libsqlite3-dev python3.12
```

- `nasm` and `gcc` assemble and link the binary.
- `libgmp-dev`, `zlib1g-dev`, `libbz2-dev`, `liblzma-dev`, `libssl-dev`,
  `libexpat1-dev`, `libffi-dev`, and `libsqlite3-dev` back arbitrary-precision
  integers and standard-library modules (`zlib`, `bz2`, `lzma`, `ssl`/digests,
  `pyexpat`, `ctypes`, `sqlite3`). This list matches `LDFLAGS` in
  [Makefile](Makefile) and [.github/workflows/ci.yml](.github/workflows/ci.yml).
- `python3.12` is only needed to run the differential test suites (building
  `./apython` itself does not require Python).

### Build and Run

```bash
make                    # build ./apython and compile stdlib bytecode
./apython --version     # print version

# Run a Python script, one-liner, module, or interactive session
./apython script.py
./apython -c 'print(sum(range(1000)))'
./apython -m http.server 8000

# Run CPython 3.12 bytecode directly
python3.12 -m py_compile script.py
./apython __pycache__/script.cpython-312.pyc
```

### Install

```bash
make install                          # installs under /usr/local/apython
make install PREFIX=$HOME/.local/apy  # or choose a custom prefix
```

`make install` uses CPython's directory layout (`bin/apython`,
`lib/python3.12/`, `lib/python3.12/lib-dynload/`,
`lib/python3.12/site-packages/`) so `site`, `sysconfig`, `venv`, and `pip`
resolve paths normally. The default prefix (`/usr/local/apython`) keeps it
isolated from any system CPython installation. Once installed,
`apython -m venv myenv` creates a virtual environment the standard way.

## Testing

The test suites use CPython 3.12 as an oracle and diff outputs against it. The
`-source` targets hand apython `.py` files instead of `.pyc` files to test the
in-tree compiler end to end.

| Command | What it runs |
|---------|--------------|
| `make check` | Main differential test suite, assembly linter (`src/compiler/lint.py`), and malformed-`.pyc`, arity, reentry, raise-leak, and syntax probes |
| `make check-cpython` | Curated CPython 3.12 stdlib test corpus (`tests/cpython/`, `.pyc`) |
| `make check-source` | Main test suite compiled from `.py` by apython's own compiler |
| `make check-cpython-source` | Curated CPython corpus compiled from `.py` by apython's own compiler |
| `make check-stdlib` | Import ratchet across a CPython 3.12 `Lib/` checkout (`CPYTHON_LIB=...`) |
| `make check-pkg` | Package test ratchet (`test_email`, `test_sqlite3`, etc., needs `CPYTHON_LIB`) |
| `make conformance` | Matched-ID CPython 3.12 conformance report |

## Debugging

- **Inspect compiler output and trace opcodes:**
  ```bash
  ./apython --dis '1 + 2 * 3'                       # eval-mode disassembly
  ./apython --dis -x 'def f(x): return x + 1'       # exec-mode disassembly
  ./apython -t script.py                            # trace dispatched opcodes
  ```
- **Run built-in low-level self-tests:**
  ```bash
  ./apython --selftest-value    # NaN-box encode/decode boundary checks
  ./apython --selftest-compile  # compiler encoder checks
  ./apython --selftest-alloc    # pool allocator checks
  ```
- **GDB:** Binaries are assembled with `-g -F dwarf` and frame pointers, so
  `gdb --args ./apython script.py` provides function names, backtraces, and
  `.asm` source stepping out of the box.
- **Valgrind:** Disable both internal free lists so freed blocks return
  immediately to libc and use-after-free bugs are visible:
  ```bash
  make NO_INT_FREELIST=1
  APYTHON_MALLOC=libc valgrind --leak-check=full ./apython script.py
  ```
- **Diagnostic build flags** (passed to `make`, full details in
  [Makefile](Makefile)):
  - `EXC_STRICT=1` — traps (`ud2`) if an opcode exits or a C entry runs with a
    stale pending exception.
  - `INT_STRESS=1` — heap-boxes every integer with `|n| >= 8` to exercise
    non-immediate integer paths.
  - `POOL_TINY=1` — shrinks the pool reservation to 1 MiB to stress
    pool-to-libc fallback crossover.
  - `NO_POOL=1` — compiles out the pool allocator entirely.

## Documentation

| Document | Contents |
|----------|----------|
| [ROADMAP.md](ROADMAP.md) | Project mission, measured conformance and benchmark numbers, phased work plan, and open defects |
| [DIVERGENCES.md](DIVERGENCES.md) | Known and intentional differences from CPython 3.12 and the rationale behind them |
| [valuebox.md](valuebox.md) | Design of the 64-bit NaN-boxed `Value` representation and integer boxing |
| [STYLE.md](STYLE.md) | x86-64 NASM assembly style guide and enforced `lint.py` rules |
| [lib/README.md](lib/README.md) | How vendored `stdlib/` and `lib/` C-module stand-ins work, plus license provenance |
| [Makefile](Makefile) | All build flags, probe/conformance targets, and generated-table rules (`make regen`) |

## License

apython is licensed under the MIT License — see [LICENSE](LICENSE).

The vendored CPython 3.12 standard library (`stdlib/`) and CPython-derived
files in `lib/` are covered by the Python Software Foundation License — see
[lib/LICENSE.python](lib/LICENSE.python) and [lib/README.md](lib/README.md).
