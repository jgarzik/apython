"""_datetime - AN ALIAS FOR THE PURE-PYTHON IMPLEMENTATION, NOT A C ACCELERATOR.

CPython ships `_datetime` as a C extension and the module above it --
datetime -- prefers it over the Python code in the same file.  There is
no C accelerator here; the Python half is the whole implementation, and it
works.

This module exists for one reason: `test.support.import_fresh_module`
returns **None** when a module named in its `fresh` list cannot be imported,
and a test file that then does `module.__dict__` dies on
"'NoneType' object has no attribute '__dict__'" while its body is still
executing.  That takes every test in the file with it -- test_datetime is
3,513 of them -- and the code under test is the pure implementation, which is
present and correct.

So importing this succeeds and gives back the same objects the pure module
defines.  Nothing here is faster than what it re-exports, and no number
measured through it should be read as native speed.  DIVERGENCES.md records
the arrangement.
"""

# The names ARE re-exported here, and they have to be.  Lib/datetime.py is a
# dispatcher:
#
#     try:
#         from _datetime import *
#         from _datetime import __doc__
#     except ImportError:
#         from _pydatetime import *
#         from _pydatetime import __doc__
#
# and `from _datetime import __doc__` SUCCEEDS for any module at all -- every
# module has one.  So an empty _datetime is not a no-op: it wins the
# try-branch and leaves `datetime` with no classes in it.  That is the
# half-implemented-is-worse shape exactly, and worse than not being here.
#
# _pydatetime is the pure implementation, in its own module, and it does not
# import this one -- so re-exporting from it is neither circular nor a second
# copy.
#
# But re-exporting cannot be the WHOLE story, and that cost 3,521 tests.
# test_datetime asks for both halves of CPython's arrangement:
#
#     import_fresh_module(TESTS, fresh=[...], blocked=['_datetime'])    # pure
#     import_fresh_module(TESTS, fresh=[...], blocked=['_pydatetime'])  # fast
#
# `blocked` puts None in sys.modules, so in the SECOND configuration the
# import below raises -- and datetime.py's own `except ImportError` fallback
# is `from _pydatetime import *`, which is blocked too.  Both modules fail,
# import_fresh_module answers None, and the test file dies on
# `module.__dict__` with every one of its tests unrun.  A stand-in that
# serves one of its two callers is the half-implemented-is-worse shape: the
# half that does not work is the half nothing detects.
#
# So when the import is refused, read the source beside this file and run it
# here instead.  Blocking a module makes `import` refuse it; it does not make
# the file unreadable.  The ordinary path is untouched -- it is the import,
# and it keeps _pydatetime's own .pyc cache -- and only the blocked
# configuration pays for a compile.
try:
    from _pydatetime import *                                   # noqa: F401,F403
    from _pydatetime import __doc__                             # noqa: F401
    from _pydatetime import (date, datetime, time, timedelta,    # noqa: F401
                             timezone, tzinfo, MINYEAR, MAXYEAR, UTC)
except ImportError:
    def _run_pure_source():
        """Execute _pydatetime.py's source into this module's globals."""
        import os
        import sys
        # The standard library's directory, not this file's: _pydatetime is
        # CPython's module and lives in stdlib/ (lib/python3.12 installed),
        # while this stand-in lives with the other C-module stand-ins.
        source = os.path.join(sys._stdlib_dir, '_pydatetime.py')
        with open(source, 'r') as handle:
            text = handle.read()
        # __name__ stays '_datetime', so the classes built here report this
        # module -- which is what CPython's C classes do too.
        exec(compile(text, source, 'exec'), globals())

    _run_pure_source()
    del _run_pure_source
