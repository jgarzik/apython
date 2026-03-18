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
	@echo "Compiling tests/cpython/test_generators.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_generators.py
	@echo "Compiling tests/cpython/test_unary.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_unary.py
	@echo "Compiling tests/cpython/test_pow.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_pow.py
	@echo "Compiling tests/cpython/test_contains.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_contains.py
	@echo "Compiling tests/cpython/test_exception_variations.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_exception_variations.py
	@echo "Compiling tests/cpython/test_genexps.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_genexps.py
	@echo "Compiling tests/cpython/test_listcomps.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_listcomps.py
	@echo "Compiling tests/cpython/test_raise.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_raise.py
	@echo "Compiling tests/cpython/test_class.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_class.py
	@echo "Compiling tests/cpython/test_compare.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_compare.py
	@echo "Compiling tests/cpython/test_with.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_with.py
	@echo "Compiling tests/cpython/test_opcodes.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_opcodes.py
	@echo "Compiling tests/cpython/test_baseexception.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_baseexception.py
	@echo "Compiling tests/cpython/test_extcall.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_extcall.py
	@echo "Compiling tests/cpython/test_iter.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_iter.py
	@echo "Compiling tests/cpython/test_lambda.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_lambda.py
	@echo "Compiling tests/cpython/test_property.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_property.py
	@echo "Compiling tests/cpython/test_string.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_string.py
	@echo "Compiling tests/cpython/test_bytes.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_bytes.py
	@echo "Compiling tests/cpython/test_builtin.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_builtin.py
	@echo "Compiling tests/cpython/test_types.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_types.py
	@echo "Compiling tests/cpython/test_closures.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_closures.py
	@echo "Compiling tests/cpython/test_dict_extra.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_dict_extra.py
	@echo "Compiling tests/cpython/test_tuple_extra.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_tuple_extra.py
	@echo "Compiling tests/cpython/test_set_extra.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_set_extra.py
	@echo "Compiling tests/cpython/test_list_extra.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_list_extra.py
	@echo "Compiling tests/cpython/test_controlflow.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_controlflow.py
	@echo "Compiling tests/cpython/test_math_basic.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_math_basic.py
	@echo "Compiling tests/cpython/test_global_nonlocal.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_global_nonlocal.py
	@echo "Compiling tests/cpython/test_unpacking.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_unpacking.py
	@echo "Compiling tests/cpython/test_inheritance.py..."
	@$(PYTHON) -m py_compile tests/cpython/test_inheritance.py
	@$(PYTHON) -m py_compile tests/cpython/test_del.py
	@$(PYTHON) -m py_compile tests/cpython/test_assert.py
	@$(PYTHON) -m py_compile tests/cpython/test_assignment.py
	@$(PYTHON) -m py_compile tests/cpython/test_exceptions_extra.py
	@$(PYTHON) -m py_compile tests/cpython/test_generators_extra.py
	@$(PYTHON) -m py_compile tests/cpython/test_format.py
	@$(PYTHON) -m py_compile tests/cpython/test_slice_ops.py
	@$(PYTHON) -m py_compile tests/cpython/test_numeric.py
	@$(PYTHON) -m py_compile tests/cpython/test_comprehensions.py
	@$(PYTHON) -m py_compile tests/cpython/test_decorators_extra.py
	@$(PYTHON) -m py_compile tests/cpython/test_walrus.py
	@$(PYTHON) -m py_compile tests/cpython/test_match.py
	@$(PYTHON) -m py_compile tests/cpython/test_datastructures.py
	@$(PYTHON) -m py_compile tests/cpython/test_exceptions_builtin.py
	@$(PYTHON) -m py_compile tests/cpython/test_functions.py
	@$(PYTHON) -m py_compile tests/cpython/test_range_extra.py
	@$(PYTHON) -m py_compile tests/cpython/test_conditional.py
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
	@-./apython tests/cpython/__pycache__/test_list.cpython-312.pyc
	@echo "Running CPython test_tuple.py..."
	@-./apython tests/cpython/__pycache__/test_tuple.cpython-312.pyc
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
	@echo "Running CPython test_generators.py..."
	@./apython tests/cpython/__pycache__/test_generators.cpython-312.pyc
	@echo "Running CPython test_unary.py..."
	@./apython tests/cpython/__pycache__/test_unary.cpython-312.pyc
	@echo "Running CPython test_pow.py..."
	@./apython tests/cpython/__pycache__/test_pow.cpython-312.pyc
	@echo "Running CPython test_contains.py..."
	@./apython tests/cpython/__pycache__/test_contains.cpython-312.pyc
	@echo "Running CPython test_exception_variations.py..."
	@./apython tests/cpython/__pycache__/test_exception_variations.cpython-312.pyc
	@echo "Running CPython test_genexps.py..."
	@./apython tests/cpython/__pycache__/test_genexps.cpython-312.pyc
	@echo "Running CPython test_listcomps.py..."
	@./apython tests/cpython/__pycache__/test_listcomps.cpython-312.pyc
	@echo "Running CPython test_raise.py..."
	@./apython tests/cpython/__pycache__/test_raise.cpython-312.pyc
	@echo "Running CPython test_class.py..."
	@./apython tests/cpython/__pycache__/test_class.cpython-312.pyc
	@echo "Running CPython test_compare.py..."
	@./apython tests/cpython/__pycache__/test_compare.cpython-312.pyc
	@echo "Running CPython test_with.py..."
	@./apython tests/cpython/__pycache__/test_with.cpython-312.pyc
	@echo "Running CPython test_opcodes.py..."
	@./apython tests/cpython/__pycache__/test_opcodes.cpython-312.pyc
	@echo "Running CPython test_baseexception.py..."
	@./apython tests/cpython/__pycache__/test_baseexception.cpython-312.pyc
	@echo "Running CPython test_extcall.py..."
	@./apython tests/cpython/__pycache__/test_extcall.cpython-312.pyc
	@echo "Running CPython test_iter.py..."
	@./apython tests/cpython/__pycache__/test_iter.cpython-312.pyc
	@echo "Running CPython test_lambda.py..."
	@./apython tests/cpython/__pycache__/test_lambda.cpython-312.pyc
	@echo "Running CPython test_property.py..."
	@./apython tests/cpython/__pycache__/test_property.cpython-312.pyc
	@echo "Running CPython test_string.py..."
	@./apython tests/cpython/__pycache__/test_string.cpython-312.pyc
	@echo "Running CPython test_bytes.py..."
	@./apython tests/cpython/__pycache__/test_bytes.cpython-312.pyc
	@echo "Running CPython test_builtin.py..."
	@./apython tests/cpython/__pycache__/test_builtin.cpython-312.pyc
	@echo "Running CPython test_types.py..."
	@./apython tests/cpython/__pycache__/test_types.cpython-312.pyc
	@echo "Running CPython test_closures.py..."
	@./apython tests/cpython/__pycache__/test_closures.cpython-312.pyc
	@echo "Running CPython test_dict_extra.py..."
	@./apython tests/cpython/__pycache__/test_dict_extra.cpython-312.pyc
	@echo "Running CPython test_tuple_extra.py..."
	@./apython tests/cpython/__pycache__/test_tuple_extra.cpython-312.pyc
	@echo "Running CPython test_set_extra.py..."
	@./apython tests/cpython/__pycache__/test_set_extra.cpython-312.pyc
	@echo "Running CPython test_list_extra.py..."
	@./apython tests/cpython/__pycache__/test_list_extra.cpython-312.pyc
	@echo "Running CPython test_controlflow.py..."
	@./apython tests/cpython/__pycache__/test_controlflow.cpython-312.pyc
	@echo "Running CPython test_math_basic.py..."
	@./apython tests/cpython/__pycache__/test_math_basic.cpython-312.pyc
	@echo "Running CPython test_global_nonlocal.py..."
	@./apython tests/cpython/__pycache__/test_global_nonlocal.cpython-312.pyc
	@echo "Running CPython test_unpacking.py..."
	@./apython tests/cpython/__pycache__/test_unpacking.cpython-312.pyc
	@echo "Running CPython test_inheritance.py..."
	@./apython tests/cpython/__pycache__/test_inheritance.cpython-312.pyc
	@echo "Running CPython test_del.py..."
	@./apython tests/cpython/__pycache__/test_del.cpython-312.pyc
	@echo "Running CPython test_assert.py..."
	@./apython tests/cpython/__pycache__/test_assert.cpython-312.pyc
	@echo "Running CPython test_assignment.py..."
	@./apython tests/cpython/__pycache__/test_assignment.cpython-312.pyc
	@echo "Running CPython test_exceptions_extra.py..."
	@./apython tests/cpython/__pycache__/test_exceptions_extra.cpython-312.pyc
	@echo "Running CPython test_generators_extra.py..."
	@./apython tests/cpython/__pycache__/test_generators_extra.cpython-312.pyc
	@echo "Running CPython test_format.py..."
	@./apython tests/cpython/__pycache__/test_format.cpython-312.pyc
	@echo "Running CPython test_slice_ops.py..."
	@./apython tests/cpython/__pycache__/test_slice_ops.cpython-312.pyc
	@echo "Running CPython test_numeric.py..."
	@./apython tests/cpython/__pycache__/test_numeric.cpython-312.pyc
	@echo "Running CPython test_comprehensions.py..."
	@./apython tests/cpython/__pycache__/test_comprehensions.cpython-312.pyc
	@echo "Running CPython test_decorators_extra.py..."
	@./apython tests/cpython/__pycache__/test_decorators_extra.cpython-312.pyc
	@echo "Running CPython test_walrus.py..."
	@./apython tests/cpython/__pycache__/test_walrus.cpython-312.pyc
	@echo "Running CPython test_match.py..."
	@./apython tests/cpython/__pycache__/test_match.cpython-312.pyc
	@echo "Running CPython test_datastructures.py..."
	@./apython tests/cpython/__pycache__/test_datastructures.cpython-312.pyc
	@echo "Running CPython test_exceptions_builtin.py..."
	@./apython tests/cpython/__pycache__/test_exceptions_builtin.cpython-312.pyc
	@echo "Running CPython test_functions.py..."
	@./apython tests/cpython/__pycache__/test_functions.cpython-312.pyc
	@echo "Running CPython test_range_extra.py..."
	@./apython tests/cpython/__pycache__/test_range_extra.cpython-312.pyc
	@echo "Running CPython test_conditional.py..."
	@./apython tests/cpython/__pycache__/test_conditional.cpython-312.pyc
