import dis
import inspect


global_value = 42


def f():
    return global_value


code = f.__code__
for locations in (code.co_lines, code.co_positions):
    entries = locations()
    assert iter(entries) is entries
    first = next(entries)
    assert (first, *entries) == tuple(locations())
    assert next(entries, None) is None

assert any(ins.argval == "global_value" for ins in dis.get_instructions(f))
assert inspect.getclosurevars(f).globals == {"global_value": 42}
