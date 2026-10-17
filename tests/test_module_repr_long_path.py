# A module's repr carries its whole __file__, however long: "<module 'm' from
# '/a/very/long/path/m.py'>".  It was built in 80-byte pieces and cut the path
# off mid-name, so a project nested a few directories deep printed
# "<module 'm' from '/home/.../src/pk'>".
import os
import sys
import tempfile

with tempfile.TemporaryDirectory() as tmp:
    deep = os.path.join(tmp, *(["a_rather_long_directory_name"] * 6))
    os.makedirs(deep)
    with open(os.path.join(deep, "longpathmod.py"), "w") as fh:
        fh.write("X = 1\n")
    sys.path.insert(0, deep)
    import longpathmod
    r = repr(longpathmod)
    print(r == "<module 'longpathmod' from %r>" % longpathmod.__file__)
    print(len(r) > 200, r.endswith("longpathmod.py'>"))
    pkgdir = os.path.join(deep, "longpathpkg")
    os.mkdir(pkgdir)
    open(os.path.join(pkgdir, "__init__.py"), "w").close()
    import importlib
    importlib.invalidate_caches()
    import longpathpkg
    print(repr(longpathpkg) == "<module 'longpathpkg' from %r>" % longpathpkg.__file__)
    sys.path.remove(deep)
