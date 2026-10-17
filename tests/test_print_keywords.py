# print() takes sep, end, file and flush, and refuses any other keyword as
# CPython does: "'x' is an invalid keyword argument for print()".  It ignored
# them, which is what six's own test of six.print_ caught.
import io

buf = io.StringIO()
print("a", "b", sep="-", end="!\n", file=buf, flush=True)
print(repr(buf.getvalue()))
for kw in ({"x": 3}, {"sep": "", "bogus": 1}, {"End": "\n"}):
    try:
        print("visible?", **kw)
    except TypeError as e:
        print("TypeError:", e)
for bad in ({"sep": 5}, {"end": 5}, {"file": 5}):
    try:
        print("z", **bad)
    except (TypeError, AttributeError) as e:
        print(type(e).__name__ + ":", e)
