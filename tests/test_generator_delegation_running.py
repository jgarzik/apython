"""Delegated throw and close cannot resume the outer generator."""


class Delegate:
    def __iter__(self):
        return self

    def __next__(self):
        return 1

    def check_outer(self):
        assert self.outer.gi_running
        try:
            next(self.outer)
        except ValueError:
            return
        raise AssertionError("re-entered a running generator")

    def throw(self, *exc):
        self.check_outer()
        return 2

    def close(self):
        self.check_outer()
        self.closed = True


def outer(delegate):
    yield from delegate


delegate = Delegate()
gen = delegate.outer = outer(delegate)
assert next(gen) == 1
assert gen.throw(ValueError()) == 2
assert not gen.gi_running
assert next(gen) == 1
gen.close()
assert delegate.closed
assert not gen.gi_running
print("delegator is running in throw and close")
