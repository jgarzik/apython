# A namespace that is not a mapping: LOAD_NAME and SETUP_ANNOTATIONS ask it
# for a name with a str key, and what a str, a list or a tuple answers that
# with is a TypeError -- not a miss.  Only a KeyError is a miss.  When the
# builtin __getitem__ began RETURNING its error the two opcodes cleared it as
# if it were one, and the body went on to store into something that is not a
# table at all.
for ns in ([], "abc", (1,), b"x", bytearray(b"x"), memoryview(b"abc")):
    for src in ("x: int = 1", "y", "x: int"):
        try:
            exec(src, {}, ns)
            print("ok")
        except Exception as e:
            print(type(ns).__name__, repr(src), type(e).__name__, e)


class Miss:
    def __init__(self):
        self.d = {}

    def __getitem__(self, key):
        return self.d[key]              # a KeyError for a miss

    def __setitem__(self, key, value):
        self.d[key] = value


class Other:
    def __getitem__(self, key):
        raise ZeroDivisionError(key)

    def __setitem__(self, key, value):
        print("set", key)


m = Miss()
exec("x: int = len('ab')", {}, m)
print(sorted(m.d))
for src in ("len", "x: int = 1"):
    try:
        exec(src, {}, Other())
        print("ok")
    except Exception as e:
        print(type(e).__name__, e)
