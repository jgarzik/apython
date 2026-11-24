"""_contextvars - context variables, as PEP 567 defines them.

CPython puts these in C because the interpreter itself swaps the current
context on every task switch.  Nothing here does that yet, so this is the
data structure and the API, with one current context that `Context.run`
swaps in and out around the call it is given.
"""

class _Missing:
    """The sentinel Token.old_value carries when the variable was unset.
    CPython's reprs as <Token.MISSING>, and code checking for it compares
    against Token.MISSING rather than testing identity with None."""

    __slots__ = ()

    def __repr__(self):
        return "<Token.MISSING>"


_NO_DEFAULT = _Missing()


class Token:
    """What `ContextVar.set` hands back, so the change can be undone."""

    __slots__ = ("_var", "_old_value", "_used")

    MISSING = _NO_DEFAULT

    def __init__(self, var, old_value):
        self._var = var
        self._old_value = old_value
        self._used = False

    @property
    def var(self):
        return self._var

    @property
    def old_value(self):
        return self._old_value

    def __repr__(self):
        used = " used" if self._used else ""
        return "<Token%s var=%r at 0x%x>" % (used, self._var, id(self))


class ContextVar:
    """One variable, looked up in whichever context is current."""

    __slots__ = ("_name", "_default")

    def __init__(self, name, *, default=_NO_DEFAULT):
        if not isinstance(name, str):
            raise TypeError("context variable name must be a str")
        self._name = name
        self._default = default

    @property
    def name(self):
        return self._name

    def get(self, default=_NO_DEFAULT):
        ctx = _current_context()
        try:
            return ctx[self]
        except KeyError:
            pass
        if default is not _NO_DEFAULT:
            return default
        if self._default is not _NO_DEFAULT:
            return self._default
        raise LookupError(self)

    def set(self, value):
        ctx = _current_context()
        old = ctx._data.get(self, _NO_DEFAULT)
        ctx._data[self] = value
        return Token(self, old)

    def reset(self, token):
        if not isinstance(token, Token):
            raise TypeError("expected an instance of Token, got %r" % (token,))
        if token._used:
            raise RuntimeError("Token has already been used once")
        if token._var is not self:
            raise ValueError("Token was created by a different ContextVar")
        ctx = _current_context()
        if token._old_value is _NO_DEFAULT:
            ctx._data.pop(self, None)
        else:
            ctx._data[self] = token._old_value
        token._used = True

    def __repr__(self):
        d = ""
        if self._default is not _NO_DEFAULT:
            d = " default=%r" % (self._default,)
        return "<ContextVar name=%r%s at 0x%x>" % (self._name, d, id(self))

    def __class_getitem__(cls, item):
        return cls


class Context:
    """A mapping from ContextVar to value, and nothing else."""

    __slots__ = ("_data", "_entered")

    def __init__(self):
        self._data = {}
        self._entered = False

    def run(self, callable, *args, **kwargs):
        if self._entered:
            raise RuntimeError(
                "cannot enter context: %r is already entered" % (self,))
        self._entered = True
        store = _thread_dict()
        saved = store.get(_KEY)
        store[_KEY] = self
        try:
            return callable(*args, **kwargs)
        finally:
            store[_KEY] = saved
            self._entered = False

    def copy(self):
        new = Context()
        new._data = dict(self._data)
        return new

    def __getitem__(self, var):
        if not isinstance(var, ContextVar):
            raise TypeError("a ContextVar key was expected, got %r" % (var,))
        return self._data[var]

    def __contains__(self, var):
        if not isinstance(var, ContextVar):
            raise TypeError("a ContextVar key was expected, got %r" % (var,))
        return var in self._data

    def get(self, var, default=None):
        if not isinstance(var, ContextVar):
            raise TypeError("a ContextVar key was expected, got %r" % (var,))
        return self._data.get(var, default)

    def __len__(self):
        return len(self._data)

    def __iter__(self):
        return iter(self._data)

    def keys(self):
        return self._data.keys()

    def values(self):
        return self._data.values()

    def items(self):
        return self._data.items()


# The current context is PER THREAD, as CPython's is: a new thread starts
# with an empty one.  It lives in the thread's own dict
# (_threadcore.thread_dict), made on first use.  When this was one global, a
# thread saw whatever the thread that started it had set -- so decimal's
# per-thread context was every thread's, and a thread that changed its
# precision changed everyone's.
from _threadcore import thread_dict as _thread_dict

_KEY = "contextvars.current"


def _current_context():
    store = _thread_dict()
    ctx = store.get(_KEY)
    if ctx is None:
        ctx = store[_KEY] = Context()
    return ctx


def copy_context():
    return _current_context().copy()
