# importlib's classes report CPython's frozen module names: the bootstrap
# module itself is importlib._bootstrap, but what it defines says
# _frozen_importlib (and _frozen_importlib_external), which is how test_bdb
# and others pick "the standard importers" out of sys.meta_path.  And a codec
# search function may answer a plain 4-tuple, which codecs.encode/decode
# accept as CPython's do.
import codecs
import importlib._bootstrap as b
import importlib._bootstrap_external as e
import sys

print(b.__name__, b.BuiltinImporter.__module__, b._find_and_load.__module__)
print(e.__name__, e.PathFinder.__module__, e.SourceFileLoader.__module__)
# Only the standard ones: a .pth file in site-packages may add more.
std = [f for f in sys.meta_path if f.__module__.startswith("_frozen_importlib")]
print([f.__name__ for f in std], [f.__module__ for f in std])


def search(name):
    if name == "tuplecodec":
        return (lambda s, errors="strict": (s.encode("ascii").upper(), len(s)),
                lambda b, errors="strict": (bytes(b).decode("ascii").lower(), len(b)),
                None, None)


codecs.register(search)
print(codecs.encode("abc", "tuplecodec"), codecs.decode(b"XYZ", "tuplecodec"))
