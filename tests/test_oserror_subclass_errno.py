import asyncio
import errno
import signal
from unittest.mock import patch


class FixedError(OSError):
    errno = errno.EINVAL


assert OSError().errno is None
assert FixedError().errno == errno.EINVAL
assert FixedError("message").errno == errno.EINVAL

loop = asyncio.new_event_loop()
try:
    with patch("asyncio.unix_events.signal.signal", side_effect=FixedError):
        try:
            loop.add_signal_handler(signal.SIGUSR1, lambda: None)
        except RuntimeError as error:
            assert str(error) == f"sig {signal.SIGUSR1} cannot be caught"
        else:
            raise AssertionError("asyncio accepted the mocked signal error")
finally:
    loop.close()

print("OSError subclass errno works in asyncio")
