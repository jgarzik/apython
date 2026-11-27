# `from m import X` where m has no X says WHICH name, from WHICH module, and
# where that module was loaded from.
#
# CPython builds three wordings in ceval.c's import_from:
#
#     cannot import name 'X' from 'm' (/path/to/m.py)
#     cannot import name 'X' from 'm' (unknown location)      -- no __file__
#     cannot import name 'X' from partially initialized module 'm'
#         (most likely due to a circular import) (/path/to/m.py)
#
# and sets `.name` to the module's name and `.path` to its file, which is how
# a caller tells "the module is missing" from "the module is there and the
# name is not".
#
# We raised a bare `ImportError: cannot import name`, with neither the name
# nor the module in it and with `.name`/`.path` unset -- so the message named
# nothing at all and told you nothing about which of the two things went
# wrong.
#
# The absolute path cannot be diffed against python3 (the stdlib lives
# somewhere else there), so this prints the message with the parenthesised
# location replaced by whether it is a real file, plus the two attributes.
#
# The partially-initialized variant is NOT covered: it needs a module
# __spec__ with _initializing set, and ours are None.  The old bug list recorded it.

import os
import re
import sys


def show(label, fn):
    try:
        fn()
    except BaseException as e:
        msg = str(e)
        # Normalise the trailing "(...)" so the two interpreters agree.
        m = re.match(r"^(.*) \((.*)\)$", msg)
        if m:
            head, loc = m.group(1), m.group(2)
            if loc == "unknown location":
                where = "unknown location"
            elif os.path.isfile(loc):
                where = "<a real file named %s>" % os.path.basename(loc)
            else:
                where = "<not a file: %r>" % loc
            msg = "%s (%s)" % (head, where)
        name = getattr(e, "name", "ABSENT")
        path = getattr(e, "path", "ABSENT")
        if isinstance(path, str) and os.path.isfile(path):
            path = "<a real file named %s>" % os.path.basename(path)
        print("%-30s %s: %s" % (label, type(e).__name__, msg))
        print("%-30s   name=%r path=%r" % ("", name, path))
    else:
        print("%-30s NO RAISE" % label)


# A package, which has a __file__.
def from_package():
    from collections import nosuchname_zzz


# A submodule of a package.
def from_submodule():
    from collections.abc import nosuchname_zzz


# A builtin module, which has no __file__ at all -> "unknown location".
def from_builtin():
    from sys import nosuchname_zzz


def from_builtin_2():
    from errno import nosuchname_zzz


# The name exists but is not importable as a submodule either.
def from_package_dotted():
    from collections import __init__zzz


# A module object synthesised by hand, with no __name__ and no __file__.
def from_nameless():
    import types

    m = types.ModuleType("temp_nameless")
    del m.__name__
    sys.modules["temp_nameless"] = m
    from temp_nameless import nosuchname_zzz


# A hand-made module WITH a name but no file.
def from_named_no_file():
    import types

    m = types.ModuleType("temp_nofile")
    sys.modules["temp_nofile"] = m
    from temp_nofile import nosuchname_zzz


show("from pkg import missing", from_package)
show("from pkg.sub import missing", from_submodule)
show("from builtin import missing", from_builtin)
show("from errno import missing", from_builtin_2)
show("from pkg import __init__zzz", from_package_dotted)
show("from nameless import missing", from_nameless)
show("from named-no-file import x", from_named_no_file)

# What must keep working: a name that IS there, and a real submodule reached
# through `from pkg import sub` even when the package body never bound it.
from collections import OrderedDict

print("real name:", OrderedDict is not None)

from collections import abc

print("real submodule:", abc.__name__)

from sys import argv

print("builtin attr:", isinstance(argv, list))

# An ImportError raised by the module's own body must not be replaced by this
# message -- the real cause has to survive.
os.makedirs("/tmp/apy_impfrom", exist_ok=True)
with open("/tmp/apy_impfrom/raiser_zzz.py", "w") as f:
    f.write("raise ImportError('the real cause')\n")
sys.path.insert(0, "/tmp/apy_impfrom")
try:
    from raiser_zzz import anything
except ImportError as e:
    print("body's own error survives:", e)
