def active():
    for resume in (lambda: next(g), lambda: g.send(None),
                   lambda: g.throw(KeyError), lambda: g.close()):
        try:
            resume()
        except ValueError as error:
            assert str(error) == "generator already executing"
            assert g.gi_running
        else:
            raise AssertionError("recursive resume succeeded")
    yield 17
    return 23


g = active()
assert next(g) == 17
try:
    next(g)
except StopIteration as stop:
    assert stop.value == 23
else:
    raise AssertionError("generator did not finish")

print("running generator rejects recursive resume")
