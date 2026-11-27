# LOAD_ATTR rewrites itself into opcode 242 when the name resolves to a
# @property whose getter is a plain one-parameter Python function, and the
# handler pushes that getter's frame directly instead of going through the
# descriptor protocol and a call.  The guard is the type's VERSION, which is
# stamped fresh by type_refresh_attr_flags whenever a class or one of its
# bases is written to and pushed down every subclass.
#
# So the cases that matter are the ones that change a class, a property or a
# getter AFTER a site has already specialized -- and every getter shape the
# handler cannot run, which must refuse to install rather than install and
# deopt for ever.  A missed invalidation here is a silently wrong answer.
#
# Every one of these reads through ONE helper, called before and after the
# change: a fresh call site is cold and takes the generic path, which is
# exactly what hides an unsound guard.


class Base:
    def __init__(self):
        self._v = 1

    @property
    def v(self):
        return self._v * 10


def read(o, n):
    total = 0
    for _ in range(n):
        total += o.v
    return total


def plain_reads():
    b = Base()
    first = read(b, 300)
    b._v = 3
    return first, read(b, 300), b.v


def the_property_is_replaced():
    class C:
        def __init__(self):
            self._v = 2

        @property
        def v(self):
            return "first"

    c = C()
    out = [read_str(c, 5)]
    C.v = property(lambda s: "second")
    out.append(read_str(c, 5))
    del C.v
    C.v = "a plain class attribute"
    out.append(read_str(c, 5))
    return out


def read_str(o, n):
    last = None
    for _ in range(n):
        last = o.v
    return last


def a_property_arrives_on_a_base():
    class B:
        pass

    class D(B):
        def __init__(self):
            self.v = "instance"

    d = D()
    out = [read_str(d, 5)]
    B.v = property(lambda s: "from base")   # a data descriptor now outranks
    out.append(read_str(d, 5))
    del B.v
    out.append(read_str(d, 5))
    return out


def the_getter_gets_a_new_code_object():
    """A function's __code__ can be assigned, and that write touches neither
    the class nor the property, so no version covers it.  The handler reads
    the code object at every hit for exactly this."""
    class C:
        def __init__(self):
            self._v = 7

        @property
        def v(self):
            return "original"

    c = C()
    out = [read_str(c, 300)]

    def replacement(self):
        return "replaced"

    C.v.fget.__code__ = replacement.__code__
    out.append(read_str(c, 300))
    return out


def the_getter_becomes_a_shape_the_cache_cannot_run():
    """The flags and the parameter count live in the CODE object, so
    assigning one is how a warm site's getter turns into something the handler
    must not run inline: a two-parameter function, and a generator."""
    class C:
        def __init__(self):
            self._v = 4

        @property
        def v(self):
            return "plain"

    c = C()
    out = [read_str(c, 300)]

    def two(self, other):
        return "two"

    C.v.fget.__code__ = two.__code__
    try:
        read_str(c, 5)
        out.append("no error")
    except TypeError as e:
        out.append("TypeError")

    def generator(self):
        yield "from a generator"

    C.v.fget.__code__ = generator.__code__
    g = None
    for _ in range(5):
        g = c.v
    out.append(list(g))
    return out


def a_getter_the_handler_cannot_run():
    """Each of these must be refused at the install site, not installed and
    deoptimized: a getter with a default, a builtin, and a generator."""
    class WithDefault:
        v = property(lambda self, k=1: ("default", k))

    class Builtin:
        v = property(len)

        def __len__(self):
            return 4

    def gen(self):
        yield 1
        yield 2

    class Generator:
        v = property(gen)

    a, b, c = WithDefault(), Builtin(), Generator()
    out = [read_str(a, 200), read_str(b, 200)]
    for _ in range(200):
        g = c.v
    out.append(sorted(g))
    return out


def the_getter_raises():
    class C:
        @property
        def v(self):
            raise ValueError("from the getter")

    c = C()
    caught = []
    for _ in range(200):
        try:
            c.v
        except ValueError as e:
            caught.append(str(e))
    return len(caught), caught[0]


# Two neighbours of these are NOT here, because apython gets them wrong for
# reasons that predate this cache and that it does not touch: a property
# SUBCLASS defining its own __get__ is not consulted, and an AttributeError out
# of a getter is propagated instead of letting __getattr__ answer.  Both are
# recorded in the old bug list.


def the_getter_raises_attribute_error():
    """An AttributeError out of a getter is not "no such attribute": getattr's
    default must still see it as a miss, and hasattr must answer False."""
    class C:
        @property
        def v(self):
            raise AttributeError("gone")

    c = C()
    out = []
    for _ in range(200):
        out.append(getattr(c, "v", "default"))
    return out[0], len(set(out)), hasattr(c, "v")


def a_getattribute_override():
    class G:
        def __init__(self):
            self._v = 1

        @property
        def v(self):
            return "property"

        def __getattribute__(self, k):
            if k == "v":
                return "intercepted"
            return object.__getattribute__(self, k)

    return read_str(G(), 200)


def two_classes_at_one_site():
    class A:
        @property
        def v(self):
            return "a"

    class B:
        @property
        def v(self):
            return "b"

    class C:
        v = "plain"

    objs = [A(), B(), C(), A()]
    out = []
    for _ in range(50):
        for o in objs:
            out.append(o.v)
    return out[:4], len(out), sorted(set(out))


def the_getter_recurses():
    class Node:
        def __init__(self, child):
            self.child = child

        @property
        def depth(self):
            if self.child is None:
                return 0
            return self.child.depth + 1

    n = None
    for _ in range(30):
        n = Node(n)
    total = 0
    for _ in range(200):
        total += n.depth
    return total


def the_getter_reads_a_global():
    """The frame the handler pushes has to carry the getter's own globals and
    builtins, not the caller's."""
    class C:
        @property
        def v(self):
            return len(str(GLOBAL_MARKER))

    return read_str(C(), 200)


GLOBAL_MARKER = 123456


def a_slotted_class():
    class S:
        __slots__ = ("_v",)

        def __init__(self):
            self._v = 9

        @property
        def v(self):
            return self._v + 1

    return read(S(), 200)


def the_property_is_in_the_instance_dict():
    """A property object stored on the INSTANCE is a value, not a descriptor:
    CPython hands it back without calling it."""
    class C:
        pass

    c = C()
    c.v = property(lambda s: "never called")
    last = None
    for _ in range(200):
        last = c.v
    return type(last).__name__


print(plain_reads())
print(the_property_is_replaced())
print(a_property_arrives_on_a_base())
print(the_getter_gets_a_new_code_object())
print(the_getter_becomes_a_shape_the_cache_cannot_run())
print(a_getter_the_handler_cannot_run())
print(the_getter_raises())
print(the_getter_raises_attribute_error())
print(a_getattribute_override())
print(two_classes_at_one_site())
print(the_getter_recurses())
print(the_getter_reads_a_global())
print(a_slotted_class())
print(the_property_is_in_the_instance_dict())
