# copy.py - Shallow and deep copy operations (minimal for apython)


class Error(Exception):
    pass


def copy(x):
    """Create a shallow copy of x."""
    cls = type(x)

    # Try __copy__
    copier = getattr(cls, '__copy__', None)
    if copier is not None:
        return copier(x)

    # Built-in immutable types: return as-is
    if isinstance(x, (int, float, bool, str, bytes, tuple, frozenset)):
        return x
    if x is None:
        return x

    # Lists
    if isinstance(x, list):
        return list(x)

    # Dicts
    if isinstance(x, dict):
        return dict(x)

    # Sets
    if isinstance(x, set):
        return set(x)

    # Bytearrays
    if isinstance(x, bytearray):
        return bytearray(x)

    # Generic: try to reconstruct
    reductor = getattr(x, '__reduce_ex__', None)
    if reductor is not None:
        rv = reductor(4)
    else:
        reductor = getattr(x, '__reduce__', None)
        if reductor is not None:
            rv = reductor()
        else:
            raise Error("un(shallow)copyable object of type %s" % cls)
    return _reconstruct(x, rv)


def deepcopy(x, memo=None):
    """Create a deep copy of x."""
    if memo is None:
        memo = {}

    d = id(x)
    y = memo.get(d)
    if y is not None:
        return y

    cls = type(x)

    # Try __deepcopy__
    copier = getattr(cls, '__deepcopy__', None)
    if copier is not None:
        y = copier(x, memo)
        memo[d] = y
        return y

    # Immutable types
    if isinstance(x, (int, float, bool, str, bytes, type)):
        return x
    if x is None:
        return x

    # Tuples
    if isinstance(x, tuple):
        y = tuple(deepcopy(item, memo) for item in x)
        memo[d] = y
        return y

    # Frozensets
    if isinstance(x, frozenset):
        y = frozenset(deepcopy(item, memo) for item in x)
        memo[d] = y
        return y

    # Lists
    if isinstance(x, list):
        y = []
        memo[d] = y
        for item in x:
            y.append(deepcopy(item, memo))
        return y

    # Dicts
    if isinstance(x, dict):
        y = {}
        memo[d] = y
        for key, value in x.items():
            y[deepcopy(key, memo)] = deepcopy(value, memo)
        return y

    # Sets
    if isinstance(x, set):
        y = set()
        memo[d] = y
        for item in x:
            y.add(deepcopy(item, memo))
        return y

    # Bytearrays
    if isinstance(x, bytearray):
        y = bytearray(x)
        memo[d] = y
        return y

    # Generic: try __reduce_ex__
    reductor = getattr(x, '__reduce_ex__', None)
    if reductor is not None:
        rv = reductor(4)
    else:
        reductor = getattr(x, '__reduce__', None)
        if reductor is not None:
            rv = reductor()
        else:
            raise Error("un(deep)copyable object of type %s" % cls)

    y = _reconstruct(x, rv)
    memo[d] = y
    return y


def _reconstruct(x, info):
    if isinstance(info, str):
        return x
    if not isinstance(info, tuple):
        raise Error("__reduce__ must return a string or tuple")
    n = len(info)
    if n < 2 or n > 5:
        raise Error("tuple returned by __reduce__ must have 2-5 elements")
    callable_obj = info[0]
    args = info[1]
    return callable_obj(*args)
