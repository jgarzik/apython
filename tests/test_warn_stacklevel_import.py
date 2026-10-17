# warn(stacklevel=N) does not count importlib's own frames: a module that
# warns about being imported reports the line that imported it, as CPython
# does, rather than a line inside importlib._bootstrap.
import sys
import warnings

warnings.simplefilter("always")
with warnings.catch_warnings(record=True) as caught:
    import warn_on_import
w = caught[0]
print(w.category.__name__, w.message, w.filename.endswith("test_warn_stacklevel_import.py"), w.lineno)


try:
    warnings.warn("x", skip_file_prefixes=["no"])
except TypeError as e:
    print(e)
