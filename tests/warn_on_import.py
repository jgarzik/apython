# Helper for test_warn_stacklevel_import: warns about its own import, the way
# pkg_resources does, so stacklevel=2 has to land on the importing line.
import warnings

warnings.warn("imported a deprecated module", DeprecationWarning, stacklevel=2)
