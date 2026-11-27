# bytes.startswith / bytes.endswith with a start and an end.
#
# str's take both; bytes' and bytearray's refused any third argument, and the
# refusal read an uninitialised frame slot for the method's name -- so the
# TypeError's text was whatever bytes sat there, machine code included.
# bytearray's went further and crashed.


def show(label, fn, *args):
    try:
        print("%-38s %s" % (label, fn(*args)))
    except Exception as e:
        # CPython qualifies an arity message with the type for its
        # clinic-generated methods and not for its hand-written ones, and
        # bytes.startswith is one of the latter; ours qualifies every one.
        # the old bug list recorded that inconsistency, so only what the message SAYS
        # is compared here, from the method name on.
        text = str(e)
        if "() takes " in text:
            text = text[text.index("() takes ") + 2:]
        print("%-38s %s: %s" % (label, type(e).__name__, text))


b = b"hello world"
a = bytearray(b"hello world")

print("-- bytes")
show("startswith(b'ell', 1)", b.startswith, b"ell", 1)
show("startswith(b'hel')", b.startswith, b"hel")
show("startswith(b'hel', 1)", b.startswith, b"hel", 1)
show("startswith(b'wor', 6)", b.startswith, b"wor", 6)
show("startswith(b'wor', -5)", b.startswith, b"wor", -5)
show("startswith(b'ell', 1, 4)", b.startswith, b"ell", 1, 4)
show("startswith(b'ell', 1, 3)", b.startswith, b"ell", 1, 3)
show("endswith(b'lo', 0, 5)", b.endswith, b"lo", 0, 5)
show("endswith(b'lo')", b.endswith, b"lo")
show("endswith(b'rld', 6)", b.endswith, b"rld", 6)
show("startswith(tuple, 1)", b.startswith, (b"zz", b"ell"), 1)
show("startswith(b'', 3, 3)", b.startswith, b"", 3, 3)
show("startswith(b'x', 99)", b.startswith, b"x", 99)
show("startswith(b'x', 0, 0)", b.startswith, b"x", 0, 0)

print()
print("-- bytearray")
show("startswith(b'ell', 1)", a.startswith, b"ell", 1)
show("endswith(b'lo', 0, 5)", a.endswith, b"lo", 0, 5)

print()
print("-- the errors")
show("startswith()", b.startswith)
show("startswith('s')", b.startswith, "s")
show("startswith(b'a', 1, 2, 3)", b.startswith, b"a", 1, 2, 3)
show("endswith()", b.endswith)
show("bytearray.startswith()", a.startswith)
