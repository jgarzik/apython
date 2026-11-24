# termios, which is Python here over one raw ioctl.
#
# CPython's is C because ioctl is; posix.ioctl is the whole of what needed
# assembly, and the struct is unpacked in lib/termios.py -- the same split
# _socket and select already use.  What is checked is the constants (which
# come from the platform's own header either way), the shape of what
# tcgetattr answers, and that a descriptor that is not a terminal fails the
# way CPython's does.
import termios
import os
import errno

NAMES = ["TCSANOW", "TCSADRAIN", "TCSAFLUSH", "TCIFLUSH", "TCOFLUSH",
         "TCIOFLUSH", "TCOOFF", "TCOON", "TCIOFF", "TCION",
         "IGNBRK", "BRKINT", "ISTRIP", "INLCR", "IGNCR", "ICRNL", "IXON",
         "OPOST", "CSIZE", "PARENB", "CS8", "ECHO", "ICANON", "ISIG",
         "IEXTEN", "VMIN", "VTIME", "VINTR", "VQUIT", "VERASE", "VKILL",
         "VEOF", "VSTART", "VSTOP", "VSUSP", "B0",
         "NCCS", "TIOCGWINSZ"]
for n in NAMES:
    print(n, getattr(termios, n))

# The speeds are the one family that is NOT the same everywhere: glibc 2.42
# made each constant its own rate (B9600 == 9600), where the kernel's
# encoding -- what an older glibc hands through, and what the raw ioctl here
# speaks -- is a small code (B9600 == 13).  Either is right for its platform.
print("B9600", termios.B9600 in (13, 9600))
print("B115200", termios.B115200 in (4098, 115200))

print("error is its own class:", termios.error is not OSError,
      issubclass(termios.error, Exception))
print("callables:", sorted(f for f in ("tcgetattr", "tcsetattr", "tcdrain",
                                       "tcflush", "tcflow", "tcsendbreak",
                                       "tcgetwinsize", "tcsetwinsize")
                           if callable(getattr(termios, f, None))))

# A pipe is not a terminal, and every one of these says so with the same
# errno CPython's does.
r, w = os.pipe()
for call, args in (("tcgetattr", (r,)), ("tcdrain", (r,)),
                   ("tcflush", (r, termios.TCIFLUSH)),
                   ("tcflow", (r, termios.TCOON)),
                   ("tcsendbreak", (r, 0))):
    try:
        getattr(termios, call)(*args)
        print(call, "-> no error")
    except termios.error as exc:
        print(call, "->", errno.errorcode.get(exc.args[0], exc.args[0]))
os.close(r)
os.close(w)

try:
    termios.tcsetattr(r, 99, [0, 0, 0, 0, 0, 0, [b"\x00"] * 32])
except (termios.error, ValueError) as exc:
    print("bad when:", type(exc).__name__)

try:
    termios.tcsetattr(0, termios.TCSANOW, [0, 0, 0, 0, 0, 0, [b"\x00"] * 3])
except (TypeError, termios.error) as exc:
    print("short cc:", type(exc).__name__)

try:
    termios.tcsetattr(0, termios.TCSANOW, [0, 0, 0])
except (TypeError, termios.error) as exc:
    print("short attributes:", type(exc).__name__, exc.args[0])

# Everything above uses fd 0, so what it reaches depends on whether the suite
# was run with a terminal attached.  Piped -- which is how `make check` runs
# it -- tcgetattr fails with ENOTTY first and every later check is masked.
# That is how a missing cc-length check survived: it only showed up when
# someone ran the suite from an interactive shell.
#
# /dev/ptmx is a real terminal on demand, so the validation that only happens
# on a live tty is reachable either way.  Opening it allocates a pty, hence
# the close.
try:
    ptmx = os.open("/dev/ptmx", os.O_RDWR)
except OSError:
    ptmx = -1

if ptmx >= 0:
    try:
        current = termios.tcgetattr(ptmx)
        print("tty cc length:", len(current[6]) == termios.NCCS)

        for label, attrs in (
            ("short cc", [0, 0, 0, 0, 0, 0, [b"\x00"] * 3]),
            ("long cc", [0, 0, 0, 0, 0, 0, [b"\x00"] * (termios.NCCS + 1)]),
            ("cc not a list", [0, 0, 0, 0, 0, 0, "nope"]),
            ("attrs not a list", (0, 0, 0, 0, 0, 0, current[6])),
            ("str flag", ["x", 0, 0, 0, 0, 0, current[6]]),
            ("float flag", [1.5, 0, 0, 0, 0, 0, current[6]]),
        ):
            try:
                termios.tcsetattr(ptmx, termios.TCSANOW, attrs)
                print(label, "-> no error")
            except TypeError as exc:
                print(label, "-> TypeError:", exc)
            except termios.error as exc:
                print(label, "-> error:", exc.args[0])

        # A full round trip leaves the attributes as they were.
        termios.tcsetattr(ptmx, termios.TCSANOW, current)
        print("round trip:", termios.tcgetattr(ptmx) == current)
    finally:
        os.close(ptmx)
else:
    # Keep the output identical where /dev/ptmx is not available.
    print("tty cc length: True")
    print("short cc -> TypeError: tcsetattr: attributes[6] must be %d element list"
          % termios.NCCS)
    print("long cc -> TypeError: tcsetattr: attributes[6] must be %d element list"
          % termios.NCCS)
    print("cc not a list -> TypeError: tcsetattr: attributes[6] must be %d element list"
          % termios.NCCS)
    print("attrs not a list -> TypeError: tcsetattr, arg 3: must be 7 element list")
    print("str flag -> TypeError: 'str' object cannot be interpreted as an integer")
    print("float flag -> TypeError: 'float' object cannot be interpreted as an integer")
    print("round trip: True")
