# PEP 562's module __getattr__ answers a MISS, and a miss is decided after the
# type has been asked: CPython's module_getattro runs the generic lookup
# first and reaches the hook only when that fails.  The hook here used to be
# asked as soon as the module's own dict had no such key, so `m.__class__`,
# `m.__reduce__` and every other name `module` or `object` supplies went to
# the hook first -- and isinstance(), which reads __class__ off everything it
# is handed, ran user code on a module that defines one.
import types

calls = []


def hook(name):
    calls.append(name)
    raise AttributeError(name)


m = types.ModuleType('m')
m.__getattr__ = hook

print(m.__class__ is types.ModuleType, calls)
print(isinstance(m, types.ModuleType), calls)
print(callable(m.__dir__), calls)
print(hasattr(m, '__reduce__'), calls)
print(m.__name__, m.__doc__, calls)
print(type(m.__dict__).__name__, calls)
print(hasattr(m, 'zzz'), calls)
print(getattr(m, 'yyy', 'default'), calls)


class Sub(types.ModuleType):
    cls_attr = 'on the class'

    def method(self):
        return 'method'


s = Sub('s')
s.__getattr__ = hook
del calls[:]
print(s.cls_attr, s.method(), calls)
try:
    s.missing
except AttributeError as e:
    print('AttributeError', calls)

answering = types.ModuleType('answering')
answering.__getattr__ = lambda name: 'hook:' + name
print(answering.absent, answering.__class__ is types.ModuleType)
