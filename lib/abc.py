# abc.py - Abstract Base Classes (minimal stub for apython)

def abstractmethod(funcobj):
    """Decorator indicating abstract methods."""
    funcobj.__isabstractmethod__ = True
    return funcobj

class ABCMeta(type):
    """Metaclass for defining Abstract Base Classes (ABCs)."""
    pass

class ABC(metaclass=ABCMeta):
    """Helper class that provides a standard way to create an ABC using inheritance."""
    __slots__ = ()
