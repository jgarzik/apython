# A tuple or frozenset subclass is filled at construction, from an iterable
# that can raise part way through.  The tuple side dereferenced the NULL the
# materialising call answered; the frozenset side handed back the half-built
# instance with the exception still pending, so it surfaced at whatever ran
# next -- outside the `try` that should have caught it.


class FS(frozenset):
    pass


class T(tuple):
    pass


class FS2(frozenset):
    def __new__(cls, it):
        return super().__new__(cls, it)


class T2(tuple):
    def __new__(cls, it):
        return super().__new__(cls, it)


def g():
    yield 1
    raise ValueError("boom")


for C in (FS, T, FS2, T2, frozenset, tuple, set, list):
    try:
        x = C(g())
        print(C.__name__, "no error", len(x))
    except ValueError as e:
        print(C.__name__, "ValueError", e)
    try:
        x = C(5)
        print(C.__name__, "no error")
    except TypeError as e:
        print(C.__name__, "TypeError")
    print(C.__name__, sorted(C([3, 1, 2])))
print("done")
