"""A write beyond RLIMIT_FSIZE raises EFBIG at the default disposition."""

import errno
import os
import resource
import signal
import tempfile


assert signal.getsignal(signal.SIGXFSZ) is signal.SIG_IGN
with tempfile.TemporaryFile() as file:
    old_limit = resource.getrlimit(resource.RLIMIT_FSIZE)
    resource.setrlimit(resource.RLIMIT_FSIZE, (1, old_limit[1]))
    try:
        assert os.write(file.fileno(), b"x") == 1
        try:
            os.write(file.fileno(), b"y")
        except OSError as exc:
            assert exc.errno == errno.EFBIG, exc
        else:
            raise AssertionError("write crossed RLIMIT_FSIZE")
    finally:
        resource.setrlimit(resource.RLIMIT_FSIZE, old_limit)

print("file size limit raises EFBIG")
