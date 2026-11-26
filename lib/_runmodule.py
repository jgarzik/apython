"""_runmodule - what `apython -m <module>` runs.

CPython's is runpy._run_module_as_main, and it is Python there for the same
reason it is Python here: finding a module means walking sys.path and asking
the import machinery, and neither exists until the interpreter has finished
starting.  So `-m` becomes a fixed bootstrap command in main.asm -- the
module name is left in sys.argv[0], which is where this reads it and where
CPython leaves the module's own file once it is resolved.

What it does NOT do is import the module.  Importing would run the body under
its own name and then again as __main__, which is both wrong and visible.  So
the source file is found, compiled, and executed in __main__'s existing
namespace -- the one main.asm already built, with __builtins__ in it.

`importlib` is deliberately not used: it is CPython's own Python package and
does not ship in lib/, so a standalone interpreter would have nothing to
call.  The parent package of a dotted name IS imported, because that is the
only way to know where to look for the child, and CPython imports it too.
"""

import sys

# The three shapes a name can resolve to, in the order CPython tries them.
# A package runs its __main__ submodule; there is no fallback to __init__,
# because `python -m json` is an error rather than a run of json/__init__.py.
_SUFFIXES = ("/__main__.py", ".py")


def _search_path(name):
    """Where to look for the last component of `name`.

    For a dotted name that is the parent package's __path__, which means the
    parent has to be imported first.  CPython does the same, and the side
    effects of importing a package to run its submodule are its own business.
    """
    parts = name.split(".")
    if len(parts) == 1:
        return sys.path, parts[0], ""
    parent = ".".join(parts[:-1])
    mod = __import__(parent)
    for part in parts[1:-1]:
        mod = getattr(mod, part)
    path = getattr(mod, "__path__", None)
    if path is None:
        raise ImportError("%s is not a package" % (parent,), name=parent)
    return list(path), parts[-1], parent


def _exists(path):
    try:
        import posix

        posix.stat(path)
        return True
    except OSError:
        return False


def _find(name):
    """-> (path, package name) for the file to run, or raise ImportError."""
    search, leaf, parent = _search_path(name)
    for d in search:
        base = d or "."
        for suffix in _SUFFIXES:
            cand = base + "/" + leaf + suffix
            if _exists(cand):
                if suffix == "/__main__.py":
                    # The module IS the package, so __package__ is the package
                    # itself rather than its parent.
                    pkg = name
                else:
                    pkg = parent
                return cand, pkg
        # A package with no __main__.py is a different error from a name that
        # is not there at all, and CPython words it separately.
        if _exists(base + "/" + leaf + "/__init__.py"):
            raise ImportError(
                "No module named %s.__main__; %r is a package and cannot be "
                "directly executed" % (name, name), name=name + ".__main__")
    raise ImportError("No module named %r" % (name,), name=name)


def run():
    """Execute the module named by sys.argv[0] in __main__'s namespace."""
    from importlib.util import spec_from_file_location

    name = sys.argv[0]
    path, pkg = _find(name)

    # sys.argv[0] becomes the module's own file, as CPython's does, so a
    # program that reports its own name reports something openable.
    sys.argv[0] = path

    with open(path, "rb") as f:
        src = f.read()
    code = compile(src, path, "exec", dont_inherit=True)

    main = sys.modules["__main__"]
    g = main.__dict__
    g["__file__"] = path
    g["__package__"] = pkg
    # A spawned child imports the original module by this name.
    spec_name = name + ".__main__" if pkg == name else name
    spec = spec_from_file_location(spec_name, path)
    g["__spec__"] = spec
    g["__loader__"] = spec.loader
    g["__cached__"] = spec.cached
    # __name__ is already "__main__" and __builtins__ is already there:
    # main.asm built this namespace before anything here ran.
    exec(code, g)
