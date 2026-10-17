# `from m import x` runs the full attribute protocol when m is an instance of
# a ModuleType subclass, as `m.x` does: six.moves is exactly that, with every
# name a lazy descriptor on the class.  IMPORT_FROM used to read the module
# type's tp_getattr alone and handed back the descriptor object itself.
import sys
import types


class Lazy:
    def __get__(self, obj, owner):
        return ("resolved", obj is not None)


class M(types.ModuleType):
    x = Lazy()

    @property
    def p(self):
        return "from a property"

    def method(self):
        return self.__name__


m = M("lazymod")
m.plain = "plain"
sys.modules["lazymod"] = m

from lazymod import x, p, plain, method
print(x, p, plain, method())

try:
    from lazymod import absent
except ImportError as e:
    print(type(e).__name__, e)
