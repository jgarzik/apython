"""_typing - the runtime objects PEP 695's syntax builds.

CPython's _typing is a C module holding TypeVar, ParamSpec, TypeVarTuple,
TypeAliasType and the Generic base.  Nothing about them needs to be C: they
are small objects with a repr, a few read-only attributes, and -- for
TypeAliasType -- a value that is not evaluated until it is asked for.

The interpreter reaches this module from the CALL_INTRINSIC_1 and
CALL_INTRINSIC_2 handlers, which is where `type X = int` and `def f[T]()`
land.  That is the same split _iocore/_io and _socketcore/_socket use: the
bytecode is the interpreter's, the objects it builds are Python's.

The laziness is the part that matters.  A bound, a constraint tuple and an
alias's value are all written as a function by the compiler and evaluated on
first access, so `type Alias = Undefined` is not an error until something
reads Alias.__value__ -- which is what lets a pair of aliases refer to each
other.
"""


def _idfunc(x):
    """-> its argument, unchanged.

    typing.py assigns it as `_SpecialForm.__call__`, so that `Any(x)` is x.
    CPython's is a C function taking exactly one argument, and the message a
    program sees when it is called wrong is that arity's.
    """
    return x


class TypeVar:
    """A type variable: `T` in `def f[T](x: T) -> T`.

    __bound__ and __constraints__ are mutually exclusive, and either may
    arrive as a thunk the compiler built -- PEP 695 evaluates a bound lazily
    so it may name a parameter declared after it.
    """

    # "__dict__" because CPython's TypeVar, ParamSpec and TypeVarTuple carry
    # a managed dict: typing_extensions -- vendored into pip -- sets
    # __default__ and has_default on them, and a slots-only instance refused.
    __slots__ = ("_name", "_bound", "_constraints", "_evaluate_bound",
                 "_evaluate_constraints", "_covariant", "_contravariant",
                 "_infer_variance", "__dict__")

    def __init__(self, name, *constraints, bound=None, covariant=False,
                 contravariant=False, infer_variance=False):
        if covariant and contravariant:
            raise ValueError("Bivariant type variables are not supported.")
        if constraints and bound is not None:
            raise TypeError("Constraints cannot be combined with bound=...")
        if len(constraints) == 1:
            raise TypeError("A single constraint is not allowed")
        self._name = name
        self._bound = bound
        self._constraints = tuple(constraints)
        self._evaluate_bound = None
        self._evaluate_constraints = None
        self._covariant = bool(covariant)
        self._contravariant = bool(contravariant)
        self._infer_variance = bool(infer_variance)

    @property
    def __name__(self):
        return self._name

    @property
    def __bound__(self):
        if self._evaluate_bound is not None:
            self._bound = self._evaluate_bound()
            self._evaluate_bound = None
        return self._bound

    @property
    def __constraints__(self):
        if self._evaluate_constraints is not None:
            self._constraints = tuple(self._evaluate_constraints())
            self._evaluate_constraints = None
        return self._constraints

    @property
    def __covariant__(self):
        return self._covariant

    @property
    def __contravariant__(self):
        return self._contravariant

    @property
    def __infer_variance__(self):
        return self._infer_variance

    def __repr__(self):
        if self._infer_variance:
            prefix = ""
        elif self._covariant:
            prefix = "+"
        elif self._contravariant:
            prefix = "-"
        else:
            prefix = "~"
        return prefix + self._name

    def __typing_subst__(self, arg):
        return arg

    # `A | int` and `int | A`.  CPython's TypeVar is a C type carrying both,
    # and what comes back is typing's own union rather than types.UnionType:
    # `typing.Union[~A, int]`.  Without them the operator said "unsupported
    # operand type(s) for |: 'TypeVar' and 'type'", which is an ordinary
    # annotation refused.  typing is imported at CALL time for the reason
    # Generic.__class_getitem__ gives -- typing imports this module first.
    def __or__(self, right):
        import typing
        return typing.Union[self, right]

    def __ror__(self, left):
        import typing
        return typing.Union[left, self]

    def __reduce__(self):
        return self._name


class ParamSpecArgs:
    __slots__ = ("__origin__",)

    def __init__(self, origin):
        self.__origin__ = origin

    def __repr__(self):
        return "%s.args" % (self.__origin__.__name__,)

    def __eq__(self, other):
        if not isinstance(other, ParamSpecArgs):
            return NotImplemented
        return self.__origin__ == other.__origin__


class ParamSpecKwargs:
    __slots__ = ("__origin__",)

    def __init__(self, origin):
        self.__origin__ = origin

    def __repr__(self):
        return "%s.kwargs" % (self.__origin__.__name__,)

    def __eq__(self, other):
        if not isinstance(other, ParamSpecKwargs):
            return NotImplemented
        return self.__origin__ == other.__origin__


class ParamSpec:
    """`**P` in `def f[**P]()`: a whole parameter list as one variable."""

    __slots__ = ("_name", "_bound", "_evaluate_bound", "_covariant",
                 "_contravariant", "_infer_variance", "__dict__")

    def __init__(self, name, *, bound=None, covariant=False,
                 contravariant=False, infer_variance=False):
        if covariant and contravariant:
            raise ValueError("Bivariant type variables are not supported.")
        self._name = name
        self._bound = bound
        self._evaluate_bound = None
        self._covariant = bool(covariant)
        self._contravariant = bool(contravariant)
        self._infer_variance = bool(infer_variance)

    @property
    def __name__(self):
        return self._name

    @property
    def __bound__(self):
        if self._evaluate_bound is not None:
            self._bound = self._evaluate_bound()
            self._evaluate_bound = None
        return self._bound

    @property
    def __covariant__(self):
        return self._covariant

    @property
    def __contravariant__(self):
        return self._contravariant

    @property
    def __infer_variance__(self):
        return self._infer_variance

    @property
    def args(self):
        return ParamSpecArgs(self)

    @property
    def kwargs(self):
        return ParamSpecKwargs(self)

    def __repr__(self):
        if self._infer_variance:
            prefix = ""
        elif self._covariant:
            prefix = "+"
        elif self._contravariant:
            prefix = "-"
        else:
            prefix = "~"
        return prefix + self._name

    def __reduce__(self):
        return self._name


class TypeVarTuple:
    """`*Ts` in `def f[*Ts]()`: any number of types as one variable."""

    __slots__ = ("_name", "__dict__")

    def __init__(self, name):
        self._name = name

    @property
    def __name__(self):
        return self._name

    def __iter__(self):
        yield Unpack(self)

    def __repr__(self):
        return self._name

    def __reduce__(self):
        return self._name


class Unpack:
    """`*Ts` where a type is wanted.  typing.Unpack, in the shape iteration
    over a TypeVarTuple produces."""

    __slots__ = ("__typing_unpacked_tuple_args__",)

    # typing's own checks read these three by name -- _is_unpacked_typevartuple
    # asks for the flag, and _collect_parameters and the Generic[...] check
    # read __origin__/__args__ off what CPython's _UnpackGenericAlias carries.
    # Without them `class C[*Ts]` was refused with "Parameters to Generic[...]
    # must all be type variables", because typing could not tell this stand-in
    # from an ordinary object.
    __typing_is_unpacked_typevartuple__ = True

    def __init__(self, arg):
        self.__typing_unpacked_tuple_args__ = arg

    @property
    def __origin__(self):
        import typing
        return typing.Unpack

    @property
    def __args__(self):
        return (self.__typing_unpacked_tuple_args__,)

    def __repr__(self):
        # typing.Unpack[Ts], which is what CPython's _UnpackGenericAlias
        # prints and what turns up in __annotations__.  "*Ts" is how the
        # SOURCE spells it, and is the repr of an unpacked GenericAlias
        # rather than of this.
        return "typing.Unpack[%s]" % (
            getattr(self.__typing_unpacked_tuple_args__, "__name__", None)
            or repr(self.__typing_unpacked_tuple_args__),)

    def __eq__(self, other):
        return (isinstance(other, Unpack)
                and self.__typing_unpacked_tuple_args__
                == other.__typing_unpacked_tuple_args__)

    def __hash__(self):
        return hash(("Unpack", id(self.__typing_unpacked_tuple_args__)))


class TypeAliasType:
    """`type X = ...`, whose value is not evaluated until it is read.

    That is the whole point of the statement form: an alias may name another
    that is defined further down the file, and a self-referential one -- `type
    Tree = int | list[Tree]` -- is only possible because nothing evaluates the
    right-hand side at definition time.
    """

    __slots__ = ("_name", "_value", "_evaluate_value", "_type_params")

    def __init__(self, name, value, *, type_params=()):
        self._name = name
        self._value = value
        self._evaluate_value = None
        self._type_params = tuple(type_params)

    @property
    def __name__(self):
        return self._name

    @property
    def __value__(self):
        if self._evaluate_value is not None:
            self._value = self._evaluate_value()
            self._evaluate_value = None
        return self._value

    @property
    def __type_params__(self):
        return self._type_params

    def __repr__(self):
        return self._name

    def __getitem__(self, args):
        return _GenericAlias(self, args if isinstance(args, tuple) else (args,))

    def __reduce__(self):
        return self._name


class _GenericAlias:
    """`Alias[int]`, kept whole rather than substituted.  Nothing in this
    interpreter inspects a subscripted alias; what matters is that the
    subscript does not raise, and that `class C[T]` -- which puts Generic[T]
    in its base list -- can say which class it stands for."""

    __slots__ = ("__origin__", "__args__")

    def __mro_entries__(self, bases):
        return (self.__origin__,)

    def __init__(self, origin, args):
        self.__origin__ = origin
        self.__args__ = args

    def __repr__(self):
        inner = ", ".join(_type_repr(a) for a in self.__args__)
        return "%s[%s]" % (_type_repr(self.__origin__), inner)

    def __eq__(self, other):
        if not isinstance(other, _GenericAlias):
            return NotImplemented
        return (self.__origin__ == other.__origin__
                and self.__args__ == other.__args__)


def _type_repr(obj):
    if isinstance(obj, type):
        if obj.__module__ == "builtins":
            return obj.__qualname__
        return "%s.%s" % (obj.__module__, obj.__qualname__)
    if obj is Ellipsis:
        return "..."
    return repr(obj)


def _typing_hook(name):
    """The typing function CPython's C Generic forwards to, or None.

    None only during bootstrap: typing.py imports Generic from this module, so
    while typing is still executing its own body the hook is not there yet and
    a `class C[T]` compiled at that moment has to fall back.
    """
    try:
        import typing
        return getattr(typing, name)
    except (ImportError, AttributeError):
        return None


class Generic:
    """The base a `class C[T]` gets.

    CPython's is a C type whose __class_getitem__ reaches back INTO typing and
    builds a `typing._GenericAlias` -- the real one, with substitution,
    `get_args`, `get_origin`, `__mro_entries__` and the rest.  Answering with
    the local stand-in below instead was the shape half-implemented-is-worse
    is about: the subscript did not raise, so nothing detected that
    `C[T][int]` said "'_GenericAlias' object is not subscriptable" and that
    every typing introspection of a user generic gave the wrong answer.

    So this does what the C one does, and for the same reason it does it
    LAZILY: typing imports this module at its own line 36, long before it has
    defined _GenericAlias, and importing typing from here at module scope
    would be circular.  The stand-in stays as the fallback for the one case
    that has no typing yet -- a `class C[T]` compiled during bootstrap.
    """

    __slots__ = ()

    # CPython's Generic is C and delegates BOTH of these to typing --
    # Objects/typevarobject.c calls _generic_class_getitem and
    # _generic_init_subclass by name.  This class IS typing.Generic (typing.py
    # imports it from here), so doing the work locally instead skipped every
    # rule the real ones carry: __init_subclass__ is what sets a subclass's
    # __parameters__, and without it Foo.__parameters__ was an AttributeError,
    # Foo[int, str] was accepted for a one-parameter Foo, get_args(Foo[None])
    # answered (None,) rather than (NoneType,), and `Generic[int]` was allowed.

    def __class_getitem__(cls, params):
        real = _typing_hook("_generic_class_getitem")
        if real is not None:
            return real(cls, params)
        # No typing yet -- a `class C[T]` compiled during bootstrap.
        if not isinstance(params, tuple):
            params = (params,)
        return _GenericAlias(cls, params)

    def __init_subclass__(cls, *args, **kwargs):
        real = _typing_hook("_generic_init_subclass")
        if real is not None:
            return real(cls, *args, **kwargs)
        super().__init_subclass__(*args, **kwargs)


# ---------------------------------------------------------------------------
# The four entry points the interpreter's intrinsics call.  Each takes what
# the bytecode has on the stack and answers the object it should push.
# ---------------------------------------------------------------------------

def _typevar(name):
    """INTRINSIC_TYPEVAR: a bare `T`, with no bound and no constraints.

    Its variance is inferred rather than declared, which is what PEP 695
    gives every type parameter -- and what makes its repr `T` where an
    explicit typing.TypeVar("T") is `~T`.
    """
    return TypeVar(name, infer_variance=True)


def _typevar_with_bound(name, evaluate_bound):
    """INTRINSIC_TYPEVAR_WITH_BOUND: `T: int`, the bound a lazy thunk.

    Its variance is inferred, as every PEP 695 parameter's is -- which is
    what makes its repr `T` rather than the `~T` an explicitly-declared
    typing.TypeVar gets.  _typevar says the same and this did not.
    """
    tv = TypeVar(name, infer_variance=True)
    tv._evaluate_bound = evaluate_bound
    return tv


def _typevar_with_constraints(name, evaluate_constraints):
    """INTRINSIC_TYPEVAR_WITH_CONSTRAINTS: `T: (int, str)`, likewise lazy,
    and with the variance inferred for the reason _typevar_with_bound gives.
    """
    tv = TypeVar(name, infer_variance=True)
    tv._evaluate_constraints = evaluate_constraints
    return tv


def _paramspec(name):
    """INTRINSIC_PARAMSPEC: `**P`, variance inferred as _typevar's is."""
    return ParamSpec(name, infer_variance=True)


def _typevartuple(name):
    """INTRINSIC_TYPEVARTUPLE: `*Ts`."""
    return TypeVarTuple(name)


def _typealias(args):
    """INTRINSIC_TYPEALIAS: (name, type_params, evaluate_value) as a tuple.

    The compiler pushes the three as one tuple, which is what the intrinsic
    receives.
    """
    name, type_params, evaluate_value = args
    alias = TypeAliasType(name, None, type_params=type_params or ())
    alias._evaluate_value = evaluate_value
    return alias


def _subscript_generic(params):
    """INTRINSIC_SUBSCRIPT_GENERIC: `Generic[T, ...]` for a generic class.

    The Generic this uses is `typing`'s when typing can be imported, which is
    what CPython does -- its intrinsic caches typing.Generic on the
    interpreter state and imports the module to get it.  It matters: a
    program that asks `issubclass(C, typing.Generic)`, or runs C past
    typing.get_type_hints or Protocol, is asking about THAT class and not
    about a lookalike.  The one below is the fallback for an interpreter with
    no typing on its path, which is what this module is for.
    """
    if not isinstance(params, tuple):
        params = (params,)
    try:
        from typing import Generic as _real
    except ImportError:
        # No typing on the path: the stand-in below is all there is.
        return _GenericAlias(Generic, params)
    # A TypeVarTuple reaches the base UNPACKED.  CPython's compiler emits
    # `Generic[*Ts]` and the star iterates it into Unpack[Ts]; ours pushes the
    # bare tuple, so the unpacking happens here instead -- and it has to,
    # because typing's own check accepts only TypeVars, ParamSpecs and
    # unpacked TypeVarTuples.
    unpacked = []
    for param in params:
        if isinstance(param, TypeVarTuple):
            unpacked.extend(param)
        else:
            unpacked.append(param)
    params = tuple(unpacked)
    # SUBSCRIPT it rather than building the alias by hand.  The two are not
    # the same object: Generic[...] goes through typing's own machinery, and
    # what comes back is the typing._GenericAlias that _collect_parameters
    # recognises.  Handing a stand-in alias to the class statement instead
    # left `class Box[T]` with an empty __parameters__ -- and then subscripting
    # it raised "Box is not a generic class".
    return _real[params]


def _set_function_type_params(func, params):
    """INTRINSIC_SET_FUNCTION_TYPE_PARAMS: `f.__type_params__ = params`."""
    func.__type_params__ = params
    return func
