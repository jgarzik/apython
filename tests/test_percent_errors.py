# What `%` does with a format it cannot use.
#
# bytes % hands a decoded copy of the format to the same engine str % uses,
# and that engine RAISED -- which abandons the C stack, so the copy and every
# converted argument were leaked, once per malformed `b"%d" % (1, 2)`.
# The old bug list said putting them somewhere the unwinder frees would be worse: an
# argument's __str__ can run Python, and a raise caught inside it would free a
# buffer the engine is still reading.
#
# So the engine reports by RETURNING instead, when asked to.  The nb_remainder
# slot cannot ask -- a NULL from a number slot means "declined", and the
# interpreter would then report "unsupported operand type(s)" over the top of
# the real message -- so bytes % re-raises once its own temporaries are gone.
#
# Two things the engine did not check at all turned up with it: an unknown
# conversion character was printed literally and consumed no argument, and the
# arity message named "string formatting" whichever type it was.

def check(label, fn):
    try:
        print(label.ljust(30), repr(fn()))
    except Exception as exc:
        print(label.ljust(30), type(exc).__name__ + ": " + str(exc))


print("=== bytes: the arity messages name bytes ===")
check("too many", lambda: b"%d" % (1, 2))
check("too few", lambda: b"%d %d" % (1,))
check("too few, %s", lambda: b"%s %s" % (b"a",))
check("none at all", lambda: b"%d" % ())
check("not a tuple, too many", lambda: b"%d" % "x")

print("=== str: the same, naming string ===")
check("too many", lambda: "%d" % (1, 2))
check("too few", lambda: "%d %d" % (1,))
check("none at all", lambda: "%s" % ())

print("=== an unknown conversion ===")
check("bytes %z", lambda: b"%z" % (1,))
check("str %z", lambda: "%z" % (1,))
check("str %q with a width", lambda: "%5q" % (1,))
check("str %b", lambda: "%b" % (1,))
check("bytes %b is real", lambda: b"%b" % (b"x",))
check("str, at the end", lambda: "abc %")
check("percent is not one", lambda: "100%% sure" % ())
check("bytes percent", lambda: b"100%% sure" % ())

print("=== mapping keys ===")
check("missing, str", lambda: "%(x)s" % {})
check("missing, other keys", lambda: "%(x)s" % {"y": 1})
check("missing, bytes", lambda: b"%(x)s" % {})
check("found, str", lambda: "%(x)s" % {"x": 1})
check("found, bytes", lambda: b"%(x)s" % {b"x": b"v"})
check("unterminated", lambda: "%(x" % {})

print("=== a * width with nothing behind it ===")
check("star, no argument", lambda: "%*d" % (6,))
check("star, both there", lambda: "%*d" % (6, 1))
check("star wants an int", lambda: "%*d" % ("x", 1))
check("star precision", lambda: "%.*f" % (2, 1.5))

print("=== and the ones that work ===")
check("bytes", lambda: b"%s-%d-%b" % (b"a", 5, b"c"))
check("str", lambda: "%s-%d-%05.2f" % ("a", 5, 1.5))
check("bytes repr", lambda: b"%r" % (b"x",))
check("bytes char", lambda: b"%c" % (65,))
print("done")


# `%%` is a literal percent, and CPython recognises it before any flag, width
# or precision has been read.  A '%' that turns up as the conversion letter
# AFTER them is neither a literal nor a conversion: "%.2%" is an unsupported
# format character, and used to come back here as a formatted number with a
# percent sign on it.
print("=== percent is a literal, not a conversion ===")
for fmt, args in (("%%", ()), ("%d%%", (5,)), ("100%%", ()), ("%%%%", ()),
                  ("%(a)s%%", {"a": 1}), ("%%%s", (1,)),
                  ("%.2%", (0.5,)), ("%5%", (1,)), ("%-5.2%", (1,)),
                  ("% %", (1,)), ("%*%", (3, 1))):
    try:
        print("%-10r %r" % (fmt, fmt % args))
    except Exception as e:
        print("%-10r %s: %s" % (fmt, type(e).__name__, e))
for fmt, args in ((b"%%", ()), (b"%d%%", (5,)), (b"%.2%", (5,))):
    try:
        print("%-10r %r" % (fmt, fmt % args))
    except Exception as e:
        print("%-10r %s: %s" % (fmt, type(e).__name__, e))
