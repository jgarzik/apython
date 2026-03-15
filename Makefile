# Makefile for apython - Python bytecode interpreter in x86-64 assembly

VERSION_MAJOR = 0
VERSION_MINOR = 6
VERSION_PATCH = 0
VERSION = $(VERSION_MAJOR).$(VERSION_MINOR).$(VERSION_PATCH)

NASM = nasm
NASMFLAGS = -f elf64 -I include/ -g -F dwarf \
    -DVERSION_MAJOR=$(VERSION_MAJOR) -DVERSION_MINOR=$(VERSION_MINOR) \
    -DVERSION_PATCH=$(VERSION_PATCH) -DVERSION_STR=\"$(VERSION)\"
CC = cc
LDFLAGS = -no-pie -lc -lgmp
TARGET = apython

# Source files
SRCS = $(wildcard src/*.asm)
PYO_SRCS = $(wildcard src/pyo/*.asm)
LIB_SRCS = $(wildcard src/lib/*.asm)
OBJS = $(SRCS:src/%.asm=build/%.o) $(PYO_SRCS:src/pyo/%.asm=build/%.o) $(LIB_SRCS:src/lib/%.asm=build/%.o)

# Python compiler for tests
PYTHON = python3

.PHONY: all clean check gen-cpython-tests check-cpython

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) -o $@ $^ $(LDFLAGS)

build/%.o: src/%.asm | build
	$(NASM) $(NASMFLAGS) -o $@ $<

build/%.o: src/pyo/%.asm | build
	$(NASM) $(NASMFLAGS) -o $@ $<

build/%.o: src/lib/%.asm | build
	$(NASM) $(NASMFLAGS) -o $@ $<

build:
	mkdir -p build

clean:
	rm -rf build $(TARGET) tests/__pycache__

# Test target: compile .py to .pyc, run both python3 and apython, diff
check: $(TARGET)
	@bash tests/run_tests.sh

# Compile a single .py to .pyc
tests/__pycache__/%.cpython-312.pyc: tests/%.py
	$(PYTHON) -m py_compile $<

# CPython test suite targets
gen-cpython-tests:
	@echo "Compiling lib/ tree..."
	@find lib -name '*.py' -exec $(PYTHON) -m py_compile {} \;
	@echo "Compiling tests/cpython/test_int.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_int.py
	@echo "Compiling tests/cpython/test_float.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_float.py
	@echo "Compiling tests/cpython/test_bool.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_bool.py
	@echo "Compiling tests/cpython/test_str_ops.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_str_ops.py
	@echo "Compiling tests/cpython/test_str_methods.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_str_methods.py
	@echo "Compiling tests/cpython/test_sort.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_sort.py
	@echo "Compiling tests/cpython/test_enumerate.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_enumerate.py
	@echo "Compiling tests/cpython/test_keywordonlyarg.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_keywordonlyarg.py
	@echo "Compiling tests/cpython/test_augassign.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_augassign.py
	@echo "Compiling tests/cpython/test_list.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_list.py
	@echo "Compiling tests/cpython/test_tuple.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_tuple.py
	@echo "Compiling tests/cpython/test_dict.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_dict.py
	@echo "Compiling tests/cpython/test_set.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_set.py
	@echo "Compiling tests/cpython/test_isinstance.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_isinstance.py
	@echo "Compiling tests/cpython/test_decorators.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_decorators.py
	@echo "Compiling tests/cpython/test_scope.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_scope.py
	@echo "Done."

check-cpython: $(TARGET) gen-cpython-tests
	@echo "Running CPython test_int.py..."
	@./apython tests/cpython/__pycache__/test_int.cpython-312.pyc
	@echo "Running CPython test_float.py..."
	@./apython tests/cpython/__pycache__/test_float.cpython-312.pyc
	@echo "Running CPython test_bool.py..."
	@./apython tests/cpython/__pycache__/test_bool.cpython-312.pyc
	@echo "Running CPython test_str_ops.py..."
	@./apython tests/cpython/__pycache__/test_str_ops.cpython-312.pyc
	@echo "Running CPython test_str_methods.py..."
	@./apython tests/cpython/__pycache__/test_str_methods.cpython-312.pyc
	@echo "Running CPython test_sort.py..."
	@./apython tests/cpython/__pycache__/test_sort.cpython-312.pyc
	@echo "Running CPython test_enumerate.py..."
	@./apython tests/cpython/__pycache__/test_enumerate.cpython-312.pyc
	@echo "Running CPython test_keywordonlyarg.py..."
	@./apython tests/cpython/__pycache__/test_keywordonlyarg.cpython-312.pyc
	@echo "Running CPython test_augassign.py..."
	@./apython tests/cpython/__pycache__/test_augassign.cpython-312.pyc
	@echo "Running CPython test_list.py..."
	@./apython tests/cpython/__pycache__/test_list.cpython-312.pyc
	@echo "Running CPython test_tuple.py..."
	@./apython tests/cpython/__pycache__/test_tuple.cpython-312.pyc
	@echo "Running CPython test_dict.py..."
	@./apython tests/cpython/__pycache__/test_dict.cpython-312.pyc
	@echo "Running CPython test_set.py..."
	@./apython tests/cpython/__pycache__/test_set.cpython-312.pyc
	@echo "Running CPython test_isinstance.py..."
	@./apython tests/cpython/__pycache__/test_isinstance.cpython-312.pyc
	@echo "Running CPython test_decorators.py..."
	@./apython tests/cpython/__pycache__/test_decorators.cpython-312.pyc
	@echo "Running CPython test_scope.py..."
	@./apython tests/cpython/__pycache__/test_scope.cpython-312.pyc
