"""_frozen_importlib - THE NAME CPython'S FROZEN importlib._bootstrap ANSWERS TO.

CPython freezes `importlib._bootstrap` into the binary and registers it under
this name, so the two are one module reached two ways.  Here the import system
is assembly and `importlib/_bootstrap.py` is an ordinary file in lib/, so the
second name did not exist -- and a module that asks for it by name got an
ImportError rather than the module it was standing right next to.

`zipimport` is the one that matters:

    import _frozen_importlib_external as _bootstrap_external
    from _frozen_importlib_external import _unpack_uint16, _unpack_uint32
    import _frozen_importlib as _bootstrap

at module scope, unguarded, and everything it then reaches for --
`_path_stat`, `_path_split`, `_classify_pyc`, `_LoaderBasics` -- is present in
our copy already, because lib/importlib is byte-identical to CPython's.

This is an alias and not a copy: `sys.modules[__name__]` is rebound to the
module itself, so `import _frozen_importlib` and `import importlib._bootstrap`
answer the same object, which is exactly CPython's arrangement.

One thing an alias cannot skip.  `importlib/__init__.py` is written as

    try:
        import _frozen_importlib as _bootstrap
    except ImportError:
        from . import _bootstrap
        _bootstrap._setup(sys, _imp)        # <-- only on the except branch

so the moment this module exists, that file stops calling `_setup`, and
`_bootstrap.sys` and `_bootstrap._imp` stay None.  A bare alias would trade an
ImportError for a broken import system.  So the injection is done here, and
done idempotently, because either module may be the first one imported.
"""

import sys
import _imp

# Importing importlib runs its __init__, whose very first act is to probe for
# THIS module -- which is half-built at this point and sitting in sys.modules.
# Left alone, __init__ binds the half-built alias, installs it under
# 'importlib._bootstrap', and then dies reading _pack_uint32 off it.
#
# Blocking the name for the duration of the re-entry is what makes the two
# agree: __init__'s probe raises, so it takes its except-ImportError branch
# and does its own wiring -- which is the wiring that was right all along.
# Then the alias is installed, once, over the top.
sys.modules[__name__] = None
try:
    from importlib import _bootstrap
finally:
    del sys.modules[__name__]

# Belt and braces for the order where importlib was imported first and took
# its else-branch instead: `_bootstrap.sys` is None until _setup has run.
if getattr(_bootstrap, 'sys', None) is None:
    _bootstrap._setup(sys, _imp)

# What CPython's frozen module looks like from outside: the module itself is
# renamed 'importlib._bootstrap' by importlib/__init__.py, but everything defined in it
# keeps '_frozen_importlib' as its __module__.  test_bdb keeps only the meta_path
# entries whose class __module__ starts with "_frozen_importlib", and pickle
# finds the classes through this name.
for _value in list(vars(_bootstrap).values()):
    if getattr(_value, "__module__", None) == 'importlib._bootstrap':
        try:
            _value.__module__ = '_frozen_importlib'
        except (AttributeError, TypeError):
            pass
del _value

sys.modules[__name__] = _bootstrap
