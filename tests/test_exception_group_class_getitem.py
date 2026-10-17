# PEP 585 on the exception groups: BaseExceptionGroup[E] and ExceptionGroup[E]
# are generic aliases, as in CPython -- pytest declares
# `class RaisesGroup(AbstractRaises[BaseExceptionGroup[BaseExcT_co]])` at
# import, and it was "type 'BaseExceptionGroup' is not subscriptable".
from typing import Generic, TypeVar

T = TypeVar("T", bound=BaseException)
print(BaseExceptionGroup[ValueError], ExceptionGroup[int])
a = BaseExceptionGroup[T]
print(a.__origin__ is BaseExceptionGroup, a.__args__, a.__parameters__)


class Holder(Generic[T]):
    pass


class H(Holder[BaseExceptionGroup[T]]):
    pass


print(H.__orig_bases__)
