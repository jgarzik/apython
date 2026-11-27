# format() ignored its spec entirely and fell through to str(); the f-string
# opcode had a partial float path that understood only a precision and a type
# letter.  So format(255, "08b") was "255" and f"{5:>5}" was "5" -- and both
# are among the most common formatting there is.
#
# The grammar is CPython's:
#   [[fill]align][sign][#][0][width][grouping][.precision][type]


def t(f):
    try:
        return repr(f())
    except Exception as e:
        return type(e).__name__


# Integer bases, with and without the alternate-form prefix
print(format(255, "b"), format(255, "o"), format(255, "x"), format(255, "X"))
print(format(255, "#b"), format(255, "#o"), format(255, "#x"), format(255, "#X"))
print(format(0, "b"), format(0, "x"), format(-255, "x"), format(255, "d"))

# Grouping
print(format(1234, "_"), format(1234567, ","), format(1234567, "_"))
print(format(-1234567, ","), format(12, ","), format(123, ","))

# Sign
print(format(42, "+"), format(42, "-"), format(42, " "), format(-42, "+"))

# Width, fill and alignment
print(format(5, ">5") + "|", format(5, "<5") + "|", format(5, "^5") + "|")
print(format("ab", ">5") + "|", format("ab", "<5") + "|", format("ab", "^5") + "|")
print(format("x", "*^5"), format("x", "-<5"), format(7, "0>4"))
print(format(-42, "05"), format(42, "05"), format(-42, "=6"))

# Precision
print(format(3.14159, ".2f"), format(3.14159, ".3f"), format(1.5, ".3f"))
print(format("abcdef", ".3"), format("ab", ".5"))

# The same through f-strings, which use the same engine
print(f"{255:08b}", f"{1234:_}", f"{5:>5}|", f"{1.5:.2f}", f"{255:#x}")
print(f"{42:+}", f"{42:^7}|", f"{1234567:,}", f"{-42:05}", f"{3.14159:.3f}")
print(f"{'ab':*^6}|", f"{'abcdef':.3}", f"{7}", f"{7!r}", f"{7:d}")
print(f"{True:d}", f"{False:d}", f"{2**40:,}")

# No spec at all still works
print(format(42), format("x"), format(1.5), f"{42}{'x'}{1.5}")


# A class with __format__ keeps control of its own spec
class Custom:
    def __format__(self, spec):
        return "custom[%s]" % spec


print(format(Custom(), ">5"), format(Custom()), f"{Custom():^9}")

# A numeric presentation cannot use the integer layout of a foreign object.
for value in ((0,), lambda: 0, object()):
    for spec in ("x", "d", "f", "s"):
        for render in (lambda: format(value, spec), lambda: f"{value:{spec}}"):
            try:
                render()
            except TypeError as exc:
                assert "unsupported format string" in str(exc), exc
            else:
                raise AssertionError(spec)

# float_format_spec rendered into a fixed 48-byte stack buffer and took
# whatever snprintf managed to fit.  format(1e300, '.2f') needs 305 bytes and
# came back truncated at 46 digits -- with the fractional part it was asked
# for missing entirely, and no sign that anything had been dropped.
# format(1e16, '.30f') was one zero short of thirty for the same reason.
#
# snprintf reports what it WOULD have written, so anything that does not fit
# is rendered again into a heap buffer of exactly that size.  The stack path
# is untouched, which is every ordinary magnitude and every repr.

BIG = 1e300
MAX = 1.7976931348623157e308

print(len(format(BIG, '.2f')), format(BIG, '.2f')[-4:])
print(format(BIG, '.2f') == format(BIG, '.0f') + '.00')
print(len(format(BIG, '.0f')), format(BIG, '.0f')[:20])
print(len(format(MAX, '.2f')), format(MAX, '.2f')[-4:])
print(len(format(BIG, '.20f')), len(format(BIG, '.30f')))
print(format(1e16, '.30f'))
print(format(1e17, '.30f') == '100000000000000000.' + '0' * 30)
print(len(format(5e-324, '.100f')), format(5e-324, '.100f')[:12])
print(format(0.1, '.50f'))

# The value survives the round trip.
print(float(format(BIG, '.2f')) == BIG, float(format(MAX, '.0f')) == MAX)
print(float(format(0.1, '.50f')) == 0.1)

# And the ordinary cases, which never leave the stack buffer.
print(format(2.675, '.2f'), format(1.0, '.6f'), format(-0.0, '.1f'))
print(format(123.456, '.2f'), format(1e22, '.2f'), format(1 / 3, '.17f'))
print(format(float('inf'), '.2f'), format(float('nan'), '.2F'))
print("%.2f|%.20f|%g" % (BIG, 0.1, 1e100))
print(repr(BIG), repr(0.1), repr(MAX))
