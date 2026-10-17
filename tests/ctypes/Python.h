/*
 * The few names Modules/_ctypes/_ctypes_test.c takes from <Python.h>.
 *
 * apython has no C API, and CPython's ctypes tests load this library with
 * CDLL(_ctypes_test.__file__) -- they call its C functions through ctypes and
 * never import it as an extension.  So the module-definition boilerplate at
 * the bottom of the file only has to compile, and the two functions that
 * would need a real interpreter (py_func_si and _testfunc_pylist_append)
 * are stubs that fail.  lib/_ctypes_test.py is the Python face of it.
 */
#ifndef APYTHON_CTYPES_TEST_PYTHON_H
#define APYTHON_CTYPES_TEST_PYTHON_H

#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>
#include <wchar.h>

#define HAVE_WCHAR_H 1

typedef struct _object { long ob_refcnt; void *ob_type; } PyObject;

#define Py_EXPORTED_SYMBOL __attribute__((visibility("default")))
#define PyMODINIT_FUNC Py_EXPORTED_SYMBOL PyObject *
#define METH_VARARGS 0x0001
#define METH_NOARGS 0x0004

typedef struct PyMethodDef {
    const char *ml_name;
    void *ml_meth;
    int ml_flags;
    const char *ml_doc;
} PyMethodDef;

typedef struct PyModuleDef_Slot { int slot; void *value; } PyModuleDef_Slot;
#define Py_mod_multiple_interpreters 3
#define Py_MOD_PER_INTERPRETER_GIL_SUPPORTED ((void *)2)

typedef struct PyModuleDef {
    PyObject ob_base;
    const char *m_name;
    const char *m_doc;
    long m_size;
    PyMethodDef *m_methods;
    PyModuleDef_Slot *m_slots;
    void *m_traverse;
    void *m_clear;
    void *m_free;
} PyModuleDef;
#define PyModuleDef_HEAD_INIT {1, NULL}

static PyObject apython_none_stub = {1, NULL};
#define Py_RETURN_NONE return &apython_none_stub

static inline int PyArg_ParseTuple(PyObject *args, const char *fmt, ...)
{ (void)args; (void)fmt; return 0; }
static inline int PyList_Append(PyObject *list, PyObject *item)
{ (void)list; (void)item; return -1; }
static inline PyObject *PyModuleDef_Init(PyModuleDef *def)
{ return (PyObject *)def; }

#endif
