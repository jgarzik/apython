"""_importlib_bootstrap - CPython's import system, installed at startup.

The name is not arbitrary: warnings skips a frame whose filename contains
both "importlib" and "_bootstrap" when it applies stacklevel, as importlib's
own are skipped, and this module's frame sits between every import
statement and _bootstrap's.

CPython runs `import` through importlib: the C half resolves the name and
checks sys.modules, and a miss calls importlib._bootstrap._find_and_load,
which walks sys.meta_path.  This module is what main runs before `site` to
make apython do the same -- what pylifecycle.c's init_importlib and
init_importlib_external do in CPython:

  * importlib._bootstrap, under its frozen name _frozen_importlib, and
    _install(), which puts BuiltinImporter and FrozenImporter on
    sys.meta_path and gives every module already loaded its __spec__;
  * importlib._bootstrap_external, and _install_external_importers(), which
    adds PathFinder and the FileFinder path hook;
  * zipimport's hook ahead of it, as CPython puts it.

From then on the interpreter's import (src/import.asm, import_find_and_load)
calls _find_and_load below on every sys.modules miss.  Until this module has
finished loading it uses its own loader instead -- which is how the modules
above are loaded at all.

_find_and_load strips importlib's own frames from the traceback of whatever
it raises, as CPython's remove_importlib_frames does in C: every one of them
for an ImportError, and otherwise each run of them that ends in
_call_with_frames_removed -- the frames between an `import` statement and
the module body that raised.
"""

import sys
import _imp
import _frozen_importlib as _bootstrap

_bootstrap._install(sys, _imp)
_bootstrap._install_external_importers()
import _frozen_importlib_external as _bootstrap_external

import zipimport
sys.path_hooks.insert(0, zipimport.zipimporter)
sys.path_importer_cache.clear()

_find_and_load_unwrapped = _bootstrap._find_and_load
_import = __import__

# Frames in these files are importlib's.  This file is one of them: its own
# frame sits between the import statement and _bootstrap's.
# Named by what the code objects say rather than by __file__: these three
# were loaded before importlib was, so nothing rewrote a relative
# co_filename to match the module's absolute __file__.
_IMPORTLIB_FILES = frozenset((
    _bootstrap._find_and_load.__code__.co_filename,
    _bootstrap_external.PathFinder.find_spec.__code__.co_filename,
    sys._getframe().f_code.co_filename,
))


def _remove_importlib_frames(exc):
    always = isinstance(exc, ImportError)
    head = exc.__traceback__
    kept = []                   # the tracebacks that stay, in order
    chunk = []                  # a run of importlib frames not yet decided
    tb = head
    while tb is not None:
        code = tb.tb_frame.f_code
        if code.co_filename in _IMPORTLIB_FILES:
            chunk.append(tb)
            if always or code.co_name == "_call_with_frames_removed":
                chunk = []      # the run so far is dropped
        else:
            kept.extend(chunk)
            chunk = []
            kept.append(tb)
        tb = tb.tb_next
    kept.extend(chunk)
    if len(kept) == 0:
        exc.__traceback__ = None
        return
    for a, b in zip(kept, kept[1:]):
        a.tb_next = b
    kept[-1].tb_next = None
    if kept[0] is not head:
        exc.__traceback__ = kept[0]


def _find_and_load(name):
    try:
        return _find_and_load_unwrapped(name, _import)
    except BaseException as exc:
        _remove_importlib_frames(exc)
        raise


_NEEDS_LOADING = object()


def _import_submodule(module, name):
    """The submodule `name` of `module` for IMPORT_FROM and `import *`, or None.

    What CPython's _handle_fromlist and import_from do between them: a
    submodule already in sys.modules is the answer; otherwise only a package
    can have one, and importing it may fail with exactly "no such
    submodule", which means absent -- anything else it raises is the
    caller's to see.
    """
    try:
        pkgname = module.__name__
    except AttributeError:
        return None
    if not isinstance(pkgname, str):
        return None
    fullname = pkgname + "." + name
    found = sys.modules.get(fullname)
    if found is not None:
        return found
    if not hasattr(module, "__path__"):
        return None
    try:
        _find_and_load_unwrapped(fullname, _import)
    except ModuleNotFoundError as exc:
        if (exc.name == fullname and
                sys.modules.get(fullname, _NEEDS_LOADING) is not None):
            return None
        _remove_importlib_frames(exc)
        raise
    except BaseException as exc:
        _remove_importlib_frames(exc)
        raise
    return sys.modules.get(fullname)
