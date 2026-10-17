# `alias | x` works for a SUBCLASS of types.GenericAlias too, as CPython's
# is_unionable accepts one: collections.abc.Callable[[Any], None] is a
# _CallableGenericAlias, and pluggy -- which pytest imports first --
# annotates with `Callable[[Any], None] | None` at module scope.  __or__ and
# __ror__ are published on GenericAlias, so a subclass inherits them by name.
import collections.abc as abc
import types
from typing import Any


class G(types.GenericAlias):
    pass


print(G(list, (int,)) | None, None | G(list, (int,)))
print(abc.Callable[[Any], None] | None)
print(int | abc.Callable[[int], str])
print(list[int] | int, list[int].__or__(5), list[int].__ror__(5))
print("__or__" in types.GenericAlias.__dict__, "__ror__" in types.GenericAlias.__dict__)
try:
    list[int] | 5
except TypeError as e:
    print("TypeError")
