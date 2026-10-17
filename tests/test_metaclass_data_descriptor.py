# type.__getattribute__'s order: a DATA descriptor found on the metaclass
# beats the class's own __dict__ (and the class's MRO); a non-data one does
# not.  zope.interface's _InterfaceMetaClass defines __module__ as a property
# and stores a descriptor under '__module__' in each class dict -- with the
# class dict winning, `cls.__module__` was a property object and the import
# failed on "unsupported operand type(s) for +: 'property' and 'str'".


class Meta(type):
    @property
    def x(cls):
        return "metaclass property"

    @property
    def __module__(cls):
        return "meta_module"

    def plain(cls):
        return "metaclass method"

    nondata = "metaclass nondata"


class C(metaclass=Meta):
    x = "class dict"
    plain = "class plain"
    nondata = "class nondata"


class D(C):
    x = "subclass dict"


print(C.x, "|", D.x)
print(C.__module__, "|", D.__module__)
print(C.plain, "|", C.nondata)
print(getattr(C, "x"), hasattr(C, "x"))
print(C().x)                     # an instance sees its class's dict

try:
    C.x = "assigned"             # a property without a setter refuses
except AttributeError as e:
    print("AttributeError")


class Setter(type):
    _v = "initial"

    @property
    def v(cls):
        return cls._v

    @v.setter
    def v(cls, value):
        type.__setattr__(cls, "_v", value)


class E(metaclass=Setter):
    v = "shadowed"


E.v = "via setter"
print(E.v, E.__dict__["v"])
