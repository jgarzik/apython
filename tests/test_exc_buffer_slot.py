# An exception type's tp_as_buffer must exist.
#
# The commit that added tp_as_buffer as PyTypeObject's 29th qword appended a
# row to all 96 LITERAL static tables and not to DEF_EXC_TYPE, the macro that
# builds every one of the hundred-odd exception types.  The tables are laid
# out back to back, so `[exc_X_type + 224]` read the NEXT table's ob_refcnt --
# 1 or 2 -- and bytes_like_ptr_len called address 2.
#
# `b"x" == ValueError("y")` was a SIGSEGV.  lint counts only literal tables
# and could not see the macro; check_macro_type_tables does now.
import io

exc = ValueError("y")
for e in (exc, TypeError(), OSError(2, "x"), ExceptionGroup("g", [KeyError()]),
          StopIteration(1), RecursionError(), UnicodeDecodeError("utf-8", b"\xff", 0, 1, "bad"),
          KeyboardInterrupt(), SystemExit(1), BaseException()):
    print(type(e).__name__, b"x" == e, e == b"x", b"x" != e)

for make, label in ((bytes, "bytes"), (bytearray, "bytearray"),
                    (memoryview, "memoryview")):
    try:
        make(exc)
        print(label, "accepted")
    except TypeError as err:
        print(label, "TypeError", err)

# `b"x" in exc` is left out: both raise TypeError, and ours omits the type
# name from the message (the old bug list recorded the wording).
for call, label in ((lambda: b"".join([exc]), "join"),
                    (lambda: b"x".find(exc), "find"),
                    (lambda: b"x" + exc, "concat"),
                    (lambda: io.BytesIO().write(exc), "BytesIO.write")):
    try:
        print(label, call())
    except TypeError as err:
        print(label, "TypeError", err)

# A user subclass of an exception inherits the slot, and so does one built by
# type() rather than by a class statement.
class MyErr(ValueError):
    pass


Made = type("Made", (KeyError,), {})
print(b"x" == MyErr("a"), b"x" == Made("a"))
print(bytes(bytearray(b"ok")))
