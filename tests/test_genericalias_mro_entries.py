# PEP 560: a subscripted builtin is a valid base.  types.GenericAlias answers
# __mro_entries__ with its origin, so `class C(list[int])` is a list subclass
# with list[int] kept in __orig_bases__.  setuptools' pkg_resources declares
# `class _ReqExtras(dict["Requirement", tuple[str, ...]])` at module scope.


class L(list[int]):
    pass


class D(dict["Requirement", tuple[str, ...]]):
    pass


print(L.__mro__)
print(L.__orig_bases__)
print(D.__mro__)
print(isinstance(L([1]), list), L([1, 2]) + [3])
print(list[int].__mro_entries__((list[int],)))
print(type.__dict__.get("__mro_entries__"))
try:
    list[int].__mro_entries__()
except TypeError as e:
    print("TypeError")
