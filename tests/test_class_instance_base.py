# A base that is not a class and has no __mro_entries__ is kept as it is,
# and with no metaclass= keyword the metaclass is type(bases[0]) -- CPython's
# update_bases and _calculate_meta.  zope.interface is written on it:
# `class IElement(Interface)`, where Interface is an InterfaceClass
# INSTANCE, calls InterfaceClass to build another one.  It was "bases must
# be types".


class InterfaceClass:
    def __init__(self, name, bases=(), attrs=None):
        self.__name__ = name
        self.__bases__ = bases
        self.names = sorted(k for k in (attrs or {}) if not k.startswith("__"))

    def __repr__(self):
        return "<InterfaceClass %s>" % self.__name__


Interface = InterfaceClass("Interface")


class IElement(Interface):
    """An element."""
    def method(self):
        pass
    attr = 1


print(type(IElement).__name__, IElement, IElement.__bases__, IElement.names)


class IChild(IElement):
    other = 2


print(IChild, IChild.__bases__ == (IElement,), IChild.names)


class Plain:
    pass


try:
    class Bad(Plain()):
        pass
except TypeError as e:
    print("TypeError:", e)
