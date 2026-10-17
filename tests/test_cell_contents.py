# A closure cell's `cell_contents`: readable, writable and deletable, as in
# CPython.  attrs reads it at import and writes it to point a method's
# __class__ cell at the class it rebuilt; jsonschema and rich import attrs.
# types.CellType constructs one, empty or holding a value.
import types


def outer():
    x = 41

    def inner():
        return x
    return inner


f = outer()
c = f.__closure__[0]
print(type(c).__name__, c.cell_contents)
c.cell_contents = 42
print(f(), c.cell_contents)
del c.cell_contents
try:
    c.cell_contents
except ValueError as e:
    print("ValueError:", e)
try:
    f()
except NameError as e:
    print("NameError")
c.cell_contents = "back"
print(f())

for op in (lambda: c.other, lambda: setattr(c, "other", 1)):
    try:
        op()
    except AttributeError as e:
        print("AttributeError:", e)

print(types.CellType(3).cell_contents)
try:
    types.CellType().cell_contents
except ValueError as e:
    print("empty:", e)
print(type(types.CellType(None)) is types.CellType)
