# Makefile for apython - Python bytecode interpreter in x86-64 assembly

VERSION_MAJOR = 0
VERSION_MINOR = 6
VERSION_PATCH = 0
VERSION = $(VERSION_MAJOR).$(VERSION_MINOR).$(VERSION_PATCH)

NASM = nasm
NASMFLAGS = -f elf64 -I src/include/ -I src/compiler/ -g -F dwarf \
    -DVERSION_MAJOR=$(VERSION_MAJOR) -DVERSION_MINOR=$(VERSION_MINOR) \
    -DVERSION_PATCH=$(VERSION_PATCH) -DVERSION_STR=\"$(VERSION)\"
# INT_STRESS=N boxes every |int| >= N as a heap PyIntObject, so the normal
# test suite exercises the heap-int paths.  Use it to shake out code that only
# handles SmallInt operands.  INT_STRESS=1 defaults the threshold to 8.
ifdef INT_STRESS
ifeq ($(INT_STRESS),1)
INT_STRESS_THRESHOLD = 8
else
INT_STRESS_THRESHOLD = $(INT_STRESS)
endif
NASMFLAGS += -DINT_STRESS_BOX=$(INT_STRESS_THRESHOLD)
endif

# NO_INT_FREELIST=1 sends every heap integer back to libc instead of onto
# int.asm's free list.  Do this when running under valgrind: a recycled block
# is not a freed one, so a use-after-free on an integer is invisible while the
# list is on.  It costs about 20% on loops whose accumulator has outgrown the
# immediate range, and nothing on anything else.
ifdef NO_INT_FREELIST
NASMFLAGS += -DNO_INT_FREELIST
endif

# NO_POOL=1 compiles the pool allocator out of src/alloc.asm, leaving the thin
# libc wrappers ap_malloc/ap_free/ap_realloc used to be.  APYTHON_MALLOC=libc
# does the same at run time, without a rebuild, and that is the one to reach
# for under valgrind: a block recycled through a size-class free list is not a
# freed block, so every use-after-free in the interpreter goes invisible while
# the pools are on.  Reach for BOTH it and NO_INT_FREELIST=1 there.
ifdef NO_POOL
NASMFLAGS += -DNO_POOL
endif

# POOL_TINY=1 shrinks the reservation from a gigabyte to a megabyte, so an
# ordinary program EXHAUSTS it and every later allocation falls through to
# libc -- which turns the whole existing corpus into a test of the crossover,
# where pool pointers and libc pointers are live at the same time and each has
# to be freed by the right one.
ifdef POOL_TINY
NASMFLAGS += -DAP_SPAN_TINY
endif

CC = cc
# -lm is for complex: hypot, pow, atan2, exp, log, cos and sin, which
# src/pyo/complex.asm calls for the general complex power and for abs().
# float.asm avoids libm by doing its own x87 sequence; complex does not, since
# the polar form needs all seven and hand-rolling them would be a worse bargain.
LDFLAGS = -no-pie -lc -lm -lgmp -lz -lcrypto -lexpat -lbz2 -llzma
TARGET = apython

# Source files.  Everything the interpreter is built from lives under src/:
# the eval loop and runtime at the top, then objects, methods and opcode
# handlers, and the Python source compiler in its own subdirectory.
SRCS = $(wildcard src/*.asm) $(wildcard src/*/*.asm)
# Objects mirror the source tree.  A flat build/ would put every basename in
# one namespace across the source directories, and a collision there is
# silent: make picks the first pattern rule whose prerequisite exists, the
# other file is never assembled, and the only symptom is a pile of undefined
# references at link time naming nothing useful.  Keeping the subdirectory in
# the stem is what avoids that -- build/pyo/dict.o and build/methods/dict.o.
OBJS = $(SRCS:src/%.asm=build/%.o)

# Every object depends on every header: nasm has no depfile support here, and
# a stale build after editing a struct layout in src/include/*.inc is a silent,
# very confusing failure.
HEADERS = $(wildcard src/include/*.inc) $(wildcard src/compiler/*.inc)

# ...and on the flags they were assembled with.  Without this, `make
# INT_STRESS=1` after an ordinary `make` finds every object up to date and
# relinks the *unstressed* binary -- so the stress run documented in CLAUDE.md
# silently proves nothing.
#
# The stamp is written while the makefile is being *parsed*, not by a rule: a
# rule's recipe runs after make has already stat'd the prerequisite graph, so
# the objects would not see the new mtime until the following invocation.  It
# is rewritten only when the flag string actually changes, so an unchanged
# setting does not force a rebuild.
FLAGSTAMP = build/.flags
$(shell mkdir -p build; printf '%s\n' '$(NASMFLAGS)' | cmp -s - $(FLAGSTAMP) \
    || printf '%s\n' '$(NASMFLAGS)' > $(FLAGSTAMP))

# Python compiler for tests
PYTHON = python3

.PHONY: all clean regen check gen-cpython-tests check-cpython check-cpython-source check-stdlib check-pkg rc-sweep rc-sweep-control check-re check-source check-pyc check-arity check-syntax check-dtoa check-round lib-pyc

all: $(TARGET) lib-pyc

# Regenerate the machine-written assembly.  Deliberately phony and deliberately
# not a prerequisite of anything: the outputs are committed so that building
# apython never needs Python, and gen_tables.py refuses to run on anything but
# CPython 3.12, so a real file rule would break the build for everyone else the
# moment a fresh clone's mtimes came out in the wrong order.
regen:
	$(PYTHON) src/compiler/gen_tables.py > src/compiler/tables.asm.new
	mv src/compiler/tables.asm.new src/compiler/tables.asm
	$(PYTHON) src/compiler/gen_prule.py
	$(PYTHON) src/compiler/gen_unicodename.py > src/compiler/unicodename.asm.new
	mv src/compiler/unicodename.asm.new src/compiler/unicodename.asm
	$(PYTHON) src/compiler/gen_unicodecase.py > src/compiler/unicodecase.asm.new
	mv src/compiler/unicodecase.asm.new src/compiler/unicodecase.asm
	$(PYTHON) src/compiler/gen_unicodedata.py > src/modules/unicodedataprops.asm.new
	mv src/modules/unicodedataprops.asm.new src/modules/unicodedataprops.asm
	$(PYTHON) src/compiler/gen_unicodenorm.py > src/modules/unicodenorm_tables.asm.new
	mv src/modules/unicodenorm_tables.asm.new src/modules/unicodenorm_tables.asm
	$(PYTHON) src/compiler/gen_ucd32.py > src/modules/ucd32_tables.asm.new
	mv src/modules/ucd32_tables.asm.new src/modules/ucd32_tables.asm
	$(PYTHON) src/compiler/gen_ast.py > lib/_ast.py.new
	mv lib/_ast.py.new lib/_ast.py
	$(PYTHON) src/compiler/gen_encodings.py lib/encodings
	$(PYTHON) src/gen_dtoa.py

$(TARGET): $(OBJS)
	$(CC) -o $@ $^ $(LDFLAGS)

# apython reads .pyc and never .py, so the modules it ships in lib/ are not
# importable until they are byte-compiled.  This is part of building the
# interpreter, not of testing it: `make check` used to run before anything
# compiled them, so any test that imported one failed on a fresh checkout.
#
# stdlib/ is CPython's own Lib/ and compiles in one compileall pass.  Neither
# is strictly needed any more -- apython compiles a .py it is handed and
# caches the result under its own apython-312 tag -- but a cold start over the
# whole standard library is slow, and CPython's bytecode is the reference.
lib-pyc:
	@find lib -name '*.py' -exec $(PYTHON) -m py_compile {} \; 2>/dev/null || true
	@$(PYTHON) -m compileall -q -j0 stdlib >/dev/null 2>&1 || true

# One rule for every source directory: the stem carries the subdirectory, so
# src/pyo/dict.asm and src/methods/dict.asm land in different objects.
build/%.o: src/%.asm $(HEADERS) $(FLAGSTAMP)
	@mkdir -p $(@D)
	$(NASM) $(NASMFLAGS) -o $@ $<

# The generated tables.asm and unicodename.asm under src/compiler are checked-in
# sources, not build products -- see `regen` below.  clean must never touch them.
clean:
	rm -rf build $(TARGET)
	find lib stdlib tests compiler -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true

# Test target: compile .py to .pyc, run both python3 and apython, diff
check: $(TARGET) lib-pyc
	@bash tests/run_tests.sh
	@bash tests/pyc_probe.sh
	@bash tests/arity_probe.sh
	@bash tests/typefuzz_probe.sh
	@bash tests/syntax_probe.sh

# A malformed .pyc has to be refused rather than run.  Not a tests/test_*.py:
# the point is what happens when the interpreter is HANDED a file, which a
# program running inside one cannot ask.
check-pyc: $(TARGET)
	@bash tests/pyc_probe.sh

# Every method of every builtin type, called with 0..3 arguments and compared
# against CPython on whether the call was refused.  Ratchets against
# tests/arity_floor.txt.
check-arity: $(TARGET)
	@bash tests/arity_probe.sh
	@bash tests/typefuzz_probe.sh

# A syntax error's message and its five location fields, against CPython's,
# over tests/syntax_corpus.txt.  Ratchets against tests/syntax_floor.txt;
# `bash tests/syntax_probe.sh --show` prints what still differs.
check-syntax: $(TARGET)
	@bash tests/syntax_probe.sh
	@bash tests/syntax_probe.sh

# Run the whole test corpus through our own compiler rather than CPython's:
# apython is handed the .py and compiles it itself.  Ratchets against
# tests/compile_floor.txt.
check-source: $(TARGET) lib-pyc
	@bash tests/source_probe.sh

# How much of CPython 3.12's own Lib/ can we import?  Ratchets against
# tests/stdlib_floor.txt.  Needs a CPython source checkout; set CPYTHON_LIB
# to point at its Lib/ directory.  Skips cleanly when it is absent.
check-stdlib: $(TARGET)
	@bash tests/stdlib_probe.sh

# CPython's PACKAGE-style test directories -- test_email/, test_unittest/,
# test_asyncio/ and eighteen more.  Every sweep before this one globbed
# Lib/test/test_*.py and so never ran any of them; three segfaulted the first
# time they were tried.  Ratchets against tests/pkg_floor.txt on the passing
# count per directory and on the crash set.  Same CPYTHON_LIB requirement as
# check-stdlib, and skips cleanly without it.
check-pkg: $(TARGET)
	@bash tests/pkg_probe.sh

# The release-candidate measurement: all of Lib/test/test_*.py, and the same
# corpus under CPython for a control.  A report, not a ratchet -- ten minutes
# a side is too long to gate on.  `make check-pkg` and `make check-stdlib`
# are the ratchets over subsets of the same ground.
rc-sweep: $(TARGET)
	@bash tests/rc_sweep.sh ap

rc-sweep-control:
	@bash tests/rc_sweep.sh cp

# The regex engine, diffed against CPython over a few hundred patterns.  Not
# in `make check`: `re` is a Python module, so it comes from $CPYTHON_LIB.
check-re: $(TARGET)
	@bash tests/re_probe.sh

# Every repr(float) the shortest-decimal conversion can be asked for, over a
# corpus far larger than make check can afford.  Not gated by default.
check-dtoa: $(TARGET)
	@bash tests/dtoa_probe.sh

# round(x, ndigits) over ~1.4 million (value, ndigits) pairs: the exact
# integer fast path and the rendering path behind it, against CPython.  Not
# gated by default, for the same reason.
check-round: $(TARGET)
	@bash tests/round_probe.sh

# CPython test suite targets
# The CPython-derived test corpus.  One list, used by both the compile step
# and the run step -- and, later, by the run-from-source variant.
CPYTHON_TESTS = \
	test_int test_float test_bool test_str_ops \
	test_str_methods test_sort test_enumerate test_keywordonlyarg \
	test_augassign test_list test_tuple test_dict \
	test_set test_isinstance test_decorators test_scope \
	test_generators test_unary test_pow test_contains \
	test_exception_variations test_genexps test_listcomps test_raise \
	test_class test_compare test_with test_opcodes \
	test_baseexception test_extcall test_iter test_lambda \
	test_property test_string test_bytes test_builtin \
	test_types test_closures test_dict_extra test_tuple_extra \
	test_set_extra test_list_extra test_controlflow test_math_basic \
	test_global_nonlocal test_unpacking test_inheritance test_del \
	test_assert test_assignment test_exceptions_extra test_generators_extra \
	test_format test_slice_ops test_numeric test_comprehensions \
	test_decorators_extra test_walrus test_match test_datastructures \
	test_exceptions_builtin test_functions test_range_extra test_conditional

gen-cpython-tests: lib-pyc
	@for t in $(CPYTHON_TESTS); do \
	    echo "Compiling tests/cpython/$$t.py..."; \
	    $(PYTHON) -m py_compile tests/cpython/$$t.py || exit 1; \
	done
	@echo "Done."

# The same corpus, compiled by OUR compiler rather than CPython's: apython is
# handed the .py.  Ratchets against tests/cpython_source_floor.txt.  It is a
# harder corpus than tests/ -- it is CPython's own, written to be adversarial --
# and most of the compiler's later bugs were found here.
check-cpython-source: $(TARGET) lib-pyc
	@bash tests/cpython_source_probe.sh

check-cpython: $(TARGET) gen-cpython-tests
	@for t in $(CPYTHON_TESTS); do \
	    echo "Running CPython $$t.py..."; \
	    ./apython tests/cpython/__pycache__/$$t.cpython-312.pyc || exit 1; \
	done
	@echo "All CPython tests passed."
