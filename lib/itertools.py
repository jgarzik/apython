"""Functional tools for creating and using iterators.

apython's stand-in for CPython's C module `itertools`, written in Python.

Every iterator here is a CLASS named as CPython names it, whose instances
report `itertools.<name>` as their type: accumulate, batched, chain (with
`chain.from_iterable` and `chain[...]`), combinations,
combinations_with_replacement, compress, count, cycle, dropwhile,
filterfalse, groupby and its `_grouper`, islice, pairwise, permutations,
product, repeat, starmap, takewhile, zip_longest, and `tee()` over `_tee`
and `_tee_dataobject`.  Each is a transcription of the C type rather than of
the documentation's rough equivalent, because real code can tell them
apart:

  - laziness and consumption: which input is advanced, how many items are
    taken and in what order -- `islice(it, 4, 1)` still skips four,
    `compress` pulls data before selectors, product and the combinatorics
    read every input up front, zip_longest stops pulling an input the
    moment it runs out;
  - groupby hands out `_grouper` views over the ONE shared iterator, so a
    group dies when the groupby advances, and the key function is called
    exactly as often as CPython calls it;
  - tee shares a buffer of 57-item `_tee_dataobject` links between its
    branches, `_tee.__copy__` is how a branch is cloned, and a branch that
    re-enters its own source raises RuntimeError;
  - argument validation and the error wordings, the reprs of count and
    repeat, `repeat.__length_hint__`, and keyword handling in subclasses
    (a subclass that defines `__init__` may take keywords the base refuses);
  - `__reduce__` / `__setstate__` in the shapes CPython 3.12 emits, each
    raising the DeprecationWarning 3.12 attaches to pickling an itertool;
    batched and pairwise, which 3.12 never taught to pickle, refuse to.

Not implemented: the result-tuple reuse the combinatorics and zip_longest
do in C (each result here is a fresh tuple), `__sizeof__`, and immutability
of the types -- `itertools.chain.foo = 1` succeeds here and is a TypeError
in CPython.  `tee` is a Python function rather than a builtin, and the
module carries private helpers CPython's does not.
"""

import sys as _sys
from _operator import index as _index

_MAXSIZE = _sys.maxsize
_LINKCELLS = 57
_NULL = object()                    # a C field that holds NULL
_object_new = object.__new__
_object_init = object.__init__
_GenericAlias = type(list[int])


def _pickle_deprecated():
    import warnings
    warnings.warn("Pickle, copy, and deepcopy support will be removed from "
                  "itertools in Python 3.14.", DeprecationWarning,
                  stacklevel=3)


def _cannot_pickle(self, *args):
    raise TypeError(f"cannot pickle 'itertools.{type(self).__name__}' object")


def _nokw(name, cls, kw):
    # CPython's tp_new refuses keywords only for the type itself or for a
    # subclass that did not bring an __init__ of its own to take them.
    if kw and cls.__init__ is _object_init:
        raise TypeError(f"{name}() takes no keyword arguments")


def _npos(name, args, lo, hi):
    n = len(args)
    if n < lo:
        raise TypeError("%s expected %s%d argument%s, got %d"
                        % (name, "" if lo == hi else "at least ", lo,
                           "" if lo == 1 else "s", n))
    if n > hi:
        raise TypeError("%s expected %s%d argument%s, got %d"
                        % (name, "" if lo == hi else "at most ", hi,
                           "" if hi == 1 else "s", n))


def _parse_tuple(args, lo, hi):
    """The arity check PyArg_ParseTuple makes, in its wording."""
    n = len(args)
    if lo <= n <= hi:
        return
    if lo == hi:
        how, want = "exactly", lo
    elif n < lo:
        how, want = "at least", lo
    else:
        how, want = "at most", hi
    raise TypeError("function takes %s %d argument%s (%d given)"
                    % (how, want, "" if want == 1 else "s", n))


def _ssize(x):
    """The `n` converter: an index that fits a Py_ssize_t."""
    if type(x) is not int:
        x = _index(x)
    if x > _MAXSIZE or x < -_MAXSIZE - 1:
        raise OverflowError("Python int too large to convert to C ssize_t")
    return x


def _ssize_or_m1(x):
    """PyNumber_AsSsize_t with every error swallowed into -1."""
    try:
        return _ssize(x)
    except Exception:
        return -1


def _as_ssize(x):
    """PyLong_AsSsize_t: an int, not merely an index."""
    if not isinstance(x, int):
        raise TypeError("an integer is required")
    return _ssize(x)


def _isiter(x):
    return hasattr(type(x), '__next__')


def _isnumber(x):
    t = type(x)
    return (hasattr(t, '__index__') or hasattr(t, '__int__')
            or hasattr(t, '__float__') or isinstance(x, complex))


def _state_tuple(state):
    if type(state) is not tuple and not isinstance(state, tuple):
        raise TypeError("state is not a tuple")


# ---------------------------------------------------------------- groupby

class groupby:
    """make an iterator that returns consecutive keys and groups from the iterable

  iterable
    Elements to divide into groups according to the key function.
  key
    A function for computing the group category for each element.
    If the key function is not specified or is None, the element itself
    is used for grouping."""

    def __new__(cls, iterable, key=None):
        self = _object_new(cls)
        self._it = iter(iterable)
        self._keyfunc = key
        self._tgtkey = self._currkey = self._currvalue = _NULL
        # CPython keeps a borrowed pointer to the live grouper; a generation
        # number answers the same question without a reference cycle.
        self._gen = 0
        return self

    def __iter__(self):
        return self

    def _step(self):
        value = next(self._it)
        kf = self._keyfunc
        key = value if kf is None else kf(value)
        self._currvalue = value
        self._currkey = key

    def __next__(self):
        self._gen += 1
        while True:
            currkey = self._currkey
            if currkey is _NULL:
                pass
            elif self._tgtkey is _NULL:
                break
            else:
                tgtkey = self._tgtkey
                if not (tgtkey is currkey or tgtkey == currkey):
                    break
            self._step()
        currkey = self._currkey
        self._tgtkey = currkey
        return (currkey, _grouper._create(_grouper, self, currkey))

    def __reduce__(self):
        _pickle_deprecated()
        if (self._tgtkey is not _NULL and self._currkey is not _NULL
                and self._currvalue is not _NULL):
            return (type(self), (self._it, self._keyfunc),
                    (self._currkey, self._currvalue, self._tgtkey))
        return (type(self), (self._it, self._keyfunc))

    def __setstate__(self, state):
        _pickle_deprecated()
        _state_tuple(state)
        _parse_tuple(state, 3, 3)
        self._currkey, self._currvalue, self._tgtkey = state


class _grouper:
    __doc__ = None

    def __new__(cls, *args, **kw):
        _nokw("_grouper", cls, kw)
        _npos("_grouper", args, 2, 2)
        parent, tgtkey = args
        if not isinstance(parent, groupby):
            raise TypeError("_grouper() argument 1 must be itertools.groupby, "
                            f"not {type(parent).__name__}")
        return cls._create(cls, parent, tgtkey)

    @staticmethod
    def _create(cls, parent, tgtkey):
        self = _object_new(cls)
        self._parent = parent
        self._tgtkey = tgtkey
        parent._gen += 1
        self._gen = parent._gen
        return self

    def __iter__(self):
        return self

    def __next__(self):
        gbo = self._parent
        if gbo._gen != self._gen:
            raise StopIteration
        if gbo._currvalue is _NULL:
            gbo._step()
        tgtkey = self._tgtkey
        currkey = gbo._currkey
        if not (tgtkey is currkey or tgtkey == currkey):
            raise StopIteration
        r = gbo._currvalue
        if r is _NULL:              # taken by a re-entrant call of ours
            raise StopIteration
        gbo._currvalue = _NULL
        gbo._currkey = _NULL
        return r

    def __reduce__(self):
        _pickle_deprecated()
        if self._parent._gen != self._gen:
            return (iter, ((),))
        return (type(self), (self._parent, self._tgtkey))


# -------------------------------------------------------------------- tee

class _tee_dataobject:
    """teedataobject(iterable, values, next, /)
--

Data container common to multiple tee objects."""

    def __new__(cls, *args, **kw):
        _nokw("teedataobject", cls, kw)
        _npos("teedataobject", args, 3, 3)
        it, values, nxt = args
        if not isinstance(values, list):
            raise TypeError("teedataobject() argument 2 must be list, "
                            f"not {type(values).__name__}")
        n = len(values)
        if n > _LINKCELLS:
            raise ValueError("Invalid arguments")
        if n == _LINKCELLS:
            if nxt is not None and type(nxt) is not _tee_dataobject:
                raise ValueError("Invalid arguments")
        elif nxt is not None:
            raise ValueError("Invalid arguments")
        self = cls._create(it)
        self._values = list(values)
        self._next = nxt
        return self

    @staticmethod
    def _create(it):
        self = _object_new(_tee_dataobject)
        self._it = it
        self._values = []
        self._next = None
        self._running = False
        return self

    def __reduce__(self):
        _pickle_deprecated()
        return (type(self), (self._it, list(self._values), self._next))


def _tee_fromiterable(iterable):
    it = iter(iterable)
    if isinstance(it, _tee):
        return it.__copy__()
    self = _object_new(_tee)
    self._data = data = _tee_dataobject._create(it)
    self._values = data._values
    self._index = 0
    return self


class _tee:
    """Iterator wrapped to make it copyable."""

    def __new__(cls, *args, **kw):
        _nokw("_tee", cls, kw)
        _npos("_tee", args, 1, 1)
        return _tee_fromiterable(args[0])

    def __iter__(self):
        return self

    def __next__(self):
        i = self._index
        values = self._values       # always self._data._values
        if i < len(values):
            self._index = i + 1
            return values[i]
        if i >= _LINKCELLS:
            return self._jump()
        data = self._data
        if data._running:
            raise RuntimeError("cannot re-enter the tee iterator")
        data._running = True
        try:
            value = next(data._it)
        finally:
            data._running = False
        values.append(value)
        self._index = i + 1
        return value

    def _jump(self):
        # On to the next link, made here if this branch is the first there.
        data = self._data
        nxt = data._next
        if nxt is None:
            nxt = data._next = _tee_dataobject._create(data._it)
        self._data = nxt
        self._values = nxt._values
        self._index = 0
        return self.__next__()

    def __copy__(self):
        new = _object_new(type(self))
        new._data = self._data
        new._values = self._values
        new._index = self._index
        return new

    def __reduce__(self):
        _pickle_deprecated()
        return (type(self), ((),), (self._data, self._index))

    def __setstate__(self, state):
        _pickle_deprecated()
        _state_tuple(state)
        _parse_tuple(state, 2, 2)
        data, index = state
        if type(data) is not _tee_dataobject:
            raise TypeError("argument 1 must be itertools._tee_dataobject, "
                            f"not {type(data).__name__}")
        index = _as_ssize(index)
        if index < 0 or index > _LINKCELLS:
            raise ValueError("Index out of range")
        self._data = data
        self._values = data._values
        self._index = index


def tee(iterable, n=2, /):
    """Returns a tuple of n independent iterators."""
    n = _ssize(n)
    if n < 0:
        raise ValueError("n must be >= 0")
    if n == 0:
        return ()
    to = _tee_fromiterable(iter(iterable))
    result = [to]
    for _ in range(n - 1):
        result.append(to.__copy__())
    return tuple(result)


# ------------------------------------------------------------------ cycle

class cycle:
    """Return elements from the iterable until it is exhausted. Then repeat the sequence indefinitely."""

    def __new__(cls, *args, **kw):
        _nokw("cycle", cls, kw)
        _npos("cycle", args, 1, 1)
        self = _object_new(cls)
        self._it = iter(args[0])
        self._saved = []
        self._firstpass = False
        self._index = 0
        return self

    def __iter__(self):
        return self

    def __next__(self):
        it = self._it
        if it is not None:
            try:
                item = next(it)
            except StopIteration:
                self._it = None
            else:
                if not self._firstpass:
                    self._saved.append(item)
                return item
        saved = self._saved
        if not saved:
            raise StopIteration
        i = self._index
        item = saved[i]
        i += 1
        self._index = 0 if i >= len(saved) else i
        return item

    def __reduce__(self):
        _pickle_deprecated()
        if self._it is None:
            it = iter(self._saved)
            if self._index:
                it.__setstate__(self._index)
            return (type(self), (it,), (self._saved, True))
        return (type(self), (self._it,), (self._saved, self._firstpass))

    def __setstate__(self, state):
        _pickle_deprecated()
        _state_tuple(state)
        _parse_tuple(state, 2, 2)
        saved, firstpass = state
        if not isinstance(saved, list):
            raise TypeError("argument 1 must be list, "
                            f"not {type(saved).__name__}")
        firstpass = _ssize(firstpass)
        self._saved = saved
        self._firstpass = firstpass != 0
        self._index = 0


# ----------------------------------------------- dropwhile, takewhile ...

class dropwhile:
    """Drop items from the iterable while predicate(item) is true.

Afterwards, return every element until the iterable is exhausted."""

    def __new__(cls, *args, **kw):
        _nokw("dropwhile", cls, kw)
        _npos("dropwhile", args, 2, 2)
        self = _object_new(cls)
        self._func = args[0]
        self._it = iter(args[1])
        self._start = False
        return self

    def __iter__(self):
        return self

    def __next__(self):
        it = self._it
        if self._start:
            return next(it)
        while True:
            item = next(it)
            if self._start:
                return item
            if not self._func(item):
                self._start = True
                return item

    def __reduce__(self):
        _pickle_deprecated()
        return (type(self), (self._func, self._it), int(self._start))

    def __setstate__(self, state):
        _pickle_deprecated()
        self._start = bool(state)


class takewhile:
    """Return successive entries from an iterable as long as the predicate evaluates to true for each entry."""

    def __new__(cls, *args, **kw):
        _nokw("takewhile", cls, kw)
        _npos("takewhile", args, 2, 2)
        self = _object_new(cls)
        self._func = args[0]
        self._it = iter(args[1])
        self._stop = False
        return self

    def __iter__(self):
        return self

    def __next__(self):
        if self._stop:
            raise StopIteration
        item = next(self._it)
        if self._func(item):
            return item
        self._stop = True
        raise StopIteration

    def __reduce__(self):
        _pickle_deprecated()
        return (type(self), (self._func, self._it), int(self._stop))

    def __setstate__(self, state):
        _pickle_deprecated()
        self._stop = bool(state)


class starmap:
    """Return an iterator whose values are returned from the function evaluated with an argument tuple taken from the given sequence."""

    def __new__(cls, *args, **kw):
        _nokw("starmap", cls, kw)
        _npos("starmap", args, 2, 2)
        self = _object_new(cls)
        self._func = args[0]
        self._it = iter(args[1])
        return self

    def __iter__(self):
        return self

    def __next__(self):
        args = next(self._it)
        if type(args) is not tuple:
            args = tuple(args)
        return self._func(*args)

    def __reduce__(self):
        _pickle_deprecated()
        return (type(self), (self._func, self._it))


class filterfalse:
    """Return those items of iterable for which function(item) is false.

If function is None, return the items that are false."""

    def __new__(cls, *args, **kw):
        _nokw("filterfalse", cls, kw)
        _npos("filterfalse", args, 2, 2)
        self = _object_new(cls)
        self._func = args[0]
        self._it = iter(args[1])
        return self

    def __iter__(self):
        return self

    def __next__(self):
        it = self._it
        func = self._func
        if func is None or func is bool:
            while True:
                item = next(it)
                if not item:
                    return item
        while True:
            item = next(it)
            if not func(item):
                return item

    def __reduce__(self):
        _pickle_deprecated()
        return (type(self), (self._func, self._it))


class compress:
    """Return data elements corresponding to true selector elements.

Forms a shorter iterator from selected data elements using the selectors to
choose the data elements."""

    def __new__(cls, data, selectors):
        self = _object_new(cls)
        self._data = iter(data)
        self._selectors = iter(selectors)
        return self

    def __iter__(self):
        return self

    def __next__(self):
        data = self._data
        selectors = self._selectors
        while True:
            datum = next(data)
            if next(selectors):
                return datum

    def __reduce__(self):
        _pickle_deprecated()
        return (type(self), (self._data, self._selectors))


# ------------------------------------------------------- accumulate, chain

class accumulate:
    """Return series of accumulated sums (or other binary function results)."""

    def __new__(cls, iterable, func=None, *, initial=None):
        self = _object_new(cls)
        self._it = iter(iterable)
        self._func = func
        self._total = _NULL
        self._initial = initial
        return self

    def __iter__(self):
        return self

    def __next__(self):
        if self._initial is not None:
            total = self._total = self._initial
            self._initial = None
            return total
        value = next(self._it)
        total = self._total
        if total is _NULL:
            total = value
        elif self._func is None:
            total = total + value
        else:
            total = self._func(total, value)
        self._total = total
        return total

    def __reduce__(self):
        _pickle_deprecated()
        func = self._func
        if self._initial is not None:
            return (type(self), (chain((self._initial,), self._it), func),
                    None)
        total = self._total
        if total is None:
            # A None total cannot travel as the state, which pickle drops.
            it = type(self)(chain((None,), self._it), func)
            return (islice, (it, 1, None))
        return (type(self), (self._it, func),
                None if total is _NULL else total)

    def __setstate__(self, state):
        _pickle_deprecated()
        self._total = state


class chain:
    """chain(*iterables) --> chain object

Return a chain object whose .__next__() method returns elements from the
first iterable until it is exhausted, then elements from the next
iterable, until all of the iterables are exhausted."""

    def __new__(cls, *args, **kw):
        _nokw("chain", cls, kw)
        self = _object_new(cls)
        self._source = iter(args)
        self._active = None
        return self

    @classmethod
    def from_iterable(cls, iterable):
        """Alternative chain() constructor taking a single iterable argument that evaluates lazily."""
        self = _object_new(cls)
        self._source = iter(iterable)
        self._active = None
        return self

    __class_getitem__ = classmethod(_GenericAlias)

    def __iter__(self):
        return self

    def __next__(self):
        active = self._active
        if active is not None:
            try:
                return next(active)
            except StopIteration:
                self._active = None
        while True:
            source = self._source
            if source is None:
                raise StopIteration
            try:
                active = iter(next(source))
            except BaseException:
                self._source = None
                raise
            self._active = active
            try:
                return next(active)
            except StopIteration:
                self._active = None

    def __reduce__(self):
        _pickle_deprecated()
        if self._source is not None:
            if self._active is not None:
                return (type(self), (), (self._source, self._active))
            return (type(self), (), (self._source,))
        return (type(self), ())

    def __setstate__(self, state):
        _pickle_deprecated()
        _state_tuple(state)
        _parse_tuple(state, 1, 2)
        source = state[0]
        active = state[1] if len(state) > 1 else None
        if not _isiter(source) or (active is not None and not _isiter(active)):
            raise TypeError("Arguments must be iterators.")
        self._source = source
        self._active = active


# ---------------------------------------------------------- the infinite

class count:
    """Return a count object whose .__next__() method returns consecutive values.

Equivalent to:
    def count(firstval=0, step=1):
        x = firstval
        while 1:
            yield x
            x += step"""

    def __new__(cls, start=0, step=1):
        if not _isnumber(start) or not _isnumber(step):
            raise TypeError("a number is required")
        if (isinstance(start, int) and isinstance(step, int) and step == 1
                and -_MAXSIZE - 1 <= start <= _MAXSIZE):
            # CPython's fast mode: a C counter, so the values are plain ints
            # whatever int subclass the arguments were.
            start = int.__index__(start)
            step = 1
        self = _object_new(cls)
        self._cnt = start
        self._step = step
        return self

    def __iter__(self):
        return self

    def __next__(self):
        cnt = self._cnt
        self._cnt = cnt + self._step
        return cnt

    def __repr__(self):
        step = self._step
        if isinstance(step, int) and step == 1:
            return f"{type(self).__name__}({self._cnt!r})"
        return f"{type(self).__name__}({self._cnt!r}, {step!r})"

    def __reduce__(self):
        _pickle_deprecated()
        step = self._step
        if type(step) is int and step == 1 and type(self._cnt) is int:
            return (type(self), (self._cnt,))
        return (type(self), (self._cnt, step))


class repeat:
    """repeat(object [,times]) -> create an iterator which returns the object
for the specified number of times.  If not specified, returns the object
endlessly."""

    def __new__(cls, object, times=_NULL):
        if times is _NULL:
            cnt = -1
        else:
            cnt = _ssize(times)
            if cnt < 0:
                cnt = 0
        self = _object_new(cls)
        self._element = object
        self._cnt = cnt
        return self

    def __iter__(self):
        return self

    def __next__(self):
        cnt = self._cnt
        if cnt:
            if cnt > 0:
                self._cnt = cnt - 1
            return self._element
        raise StopIteration

    def __length_hint__(self):
        """Private method returning an estimate of len(list(it))."""
        if self._cnt == -1:
            raise TypeError("len() of unsized object")
        return self._cnt

    def __repr__(self):
        if self._cnt == -1:
            return f"{type(self).__name__}({self._element!r})"
        return f"{type(self).__name__}({self._element!r}, {self._cnt})"

    def __reduce__(self):
        _pickle_deprecated()
        if self._cnt >= 0:
            return (type(self), (self._element, self._cnt))
        return (type(self), (self._element,))


# ----------------------------------------------------------------- islice

_ISLICE_STOP = ("Stop argument for islice() must be None or an integer: "
                "0 <= x <= sys.maxsize.")


class islice:
    """islice(iterable, stop) --> islice object
islice(iterable, start, stop[, step]) --> islice object

Return an iterator whose next() method returns selected values from an
iterable.  If start is specified, will skip all preceding elements;
otherwise, start defaults to zero.  Step defaults to one.  If
specified as another value, step determines how many values are
skipped between successive calls.  Works like a slice() on a list
but returns an iterator."""

    def __new__(cls, *args, **kw):
        if kw:
            _nokw("islice", cls, kw)
        nargs = len(args)
        if nargs == 2 and type(args[1]) is int and 0 <= args[1] <= _MAXSIZE:
            # islice(it, n), the common case, without the general parse
            start = 0
            stop = args[1]
            step = 1
        else:
            _npos("islice", args, 2, 4)
            start = 0
            stop = -1
            step = 1
            if nargs == 2:
                a1 = args[1]
                if a1 is not None:
                    stop = _ssize_or_m1(a1)
                    if stop == -1:
                        raise ValueError(_ISLICE_STOP)
            else:
                a1 = args[1]
                a2 = args[2]
                if a1 is not None:
                    start = _ssize_or_m1(a1)
                if a2 is not None:
                    stop = _ssize_or_m1(a2)
                    if stop == -1:
                        raise ValueError(_ISLICE_STOP)
            if start < 0 or stop < -1:
                raise ValueError("Indices for islice() must be None or an "
                                 "integer: 0 <= x <= sys.maxsize.")
            if nargs == 4 and args[3] is not None:
                step = _ssize_or_m1(args[3])
            if step < 1:
                raise ValueError("Step for islice() must be a positive "
                                 "integer or None.")
        self = _object_new(cls)
        self._it = iter(args[0])
        self._next = start
        self._stop = stop       # -1 is None, as in C
        self._step = step
        self._cnt = 0
        return self

    def __iter__(self):
        return self

    def __next__(self):
        it = self._it
        if it is None:
            raise StopIteration
        cnt = self._cnt
        if cnt == self._next and self._step == 1:
            # At the next index with a unit step, `next` never passes `stop`
            # (it is clamped there), so `cnt == stop` is the whole test.
            if cnt == self._stop:
                self._it = None
                raise StopIteration
            try:
                item = next(it)
            except BaseException:
                self._it = None
                raise
            self._cnt = self._next = cnt + 1
            return item
        nxt = self._next
        stop = self._stop
        try:
            while cnt < nxt:
                next(it)
                cnt += 1
                self._cnt = cnt
            if stop != -1 and cnt >= stop:
                raise StopIteration
            item = next(it)
        except BaseException:
            # Exhausted, or the source raised: either way islice lets go of
            # it, so a weak reference to the source dies here.
            self._it = None
            raise
        self._cnt = cnt + 1
        nxt += self._step
        if nxt > _MAXSIZE or (stop != -1 and nxt > stop):
            nxt = stop
        self._next = nxt
        return item

    def __reduce__(self):
        _pickle_deprecated()
        if self._it is None:
            return (type(self), (iter([]), 0), 0)
        stop = None if self._stop == -1 else self._stop
        return (type(self), (self._it, self._next, stop, self._step),
                self._cnt)

    def __setstate__(self, state):
        _pickle_deprecated()
        self._cnt = _as_ssize(state)


# -------------------------------------------------------- batched, pairwise

class batched:
    """Batch data into tuples of length n. The last batch may be shorter than n.

Loops over the input iterable and accumulates data into tuples
up to size n.  The input is consumed lazily, just enough to
fill a batch.  The result is yielded as soon as a batch is full
or when the input iterable is exhausted.

    >>> for batch in batched('ABCDEFG', 3):
    ...     print(batch)
    ...
    ('A', 'B', 'C')
    ('D', 'E', 'F')
    ('G',)"""

    def __new__(cls, iterable, n):
        n = _ssize(n)
        if n < 1:
            raise ValueError("n must be at least one")
        self = _object_new(cls)
        self._it = iter(iterable)
        self._n = n
        return self

    def __iter__(self):
        return self

    def __next__(self):
        it = self._it
        if it is None:
            raise StopIteration
        batch = []
        append = batch.append
        try:
            for _ in range(self._n):
                append(next(it))
        except StopIteration:
            if not batch:
                self._it = None
                raise
        except BaseException:
            self._it = None
            raise
        return tuple(batch)

    __reduce__ = _cannot_pickle


class pairwise:
    """Return an iterator of overlapping pairs taken from the input iterator.

    s -> (s0,s1), (s1,s2), (s2, s3), ..."""

    def __new__(cls, *args, **kw):
        _nokw("pairwise", cls, kw)
        _npos("pairwise", args, 1, 1)
        self = _object_new(cls)
        self._it = iter(args[0])
        self._old = _NULL
        return self

    def __iter__(self):
        return self

    def __next__(self):
        it = self._it
        if it is None:
            raise StopIteration
        old = self._old
        if old is _NULL:
            try:
                old = next(it)
            except BaseException:
                self._old = _NULL
                self._it = None
                raise
            self._old = old
            it = self._it
            if it is None:          # a re-entrant call exhausted it
                self._old = _NULL
                raise StopIteration
        try:
            new = next(it)
        except BaseException:
            self._it = None
            self._old = _NULL
            raise
        self._old = new
        return (old, new)

    __reduce__ = _cannot_pickle


# ------------------------------------------------------------ zip_longest

class zip_longest:
    """zip_longest(iter1 [,iter2 [...]], [fillvalue=None]) --> zip_longest object

Return a zip_longest object whose .__next__() method returns a tuple where
the i-th element comes from the i-th iterable argument.  The .__next__()
method continues until the longest iterable in the argument sequence
is exhausted and then it raises StopIteration.  When the shorter iterables
are exhausted, the fillvalue is substituted in their place.  The fillvalue
defaults to None or can be specified by a keyword argument.
"""

    def __new__(cls, *args, **kw):
        fillvalue = None
        if kw:
            if len(kw) != 1 or 'fillvalue' not in kw:
                raise TypeError(
                    "zip_longest() got an unexpected keyword argument")
            fillvalue = kw['fillvalue']
        its = [iter(a) for a in args]
        self = _object_new(cls)
        self._its = its
        self._numactive = len(its)
        self._fillvalue = fillvalue
        return self

    def __iter__(self):
        return self

    def __next__(self):
        its = self._its
        num = self._numactive
        if not num:
            raise StopIteration
        values = []
        append = values.append
        fillvalue = self._fillvalue
        i = 0
        for it in its:
            if it is None:
                append(fillvalue)
            else:
                try:
                    append(next(it))
                except StopIteration:
                    num -= 1
                    if not num:
                        self._numactive = 0
                        raise
                    its[i] = None
                    append(fillvalue)
                except BaseException:
                    self._numactive = 0
                    raise
            i += 1
        self._numactive = num
        return tuple(values)

    def __reduce__(self):
        _pickle_deprecated()
        args = tuple(() if it is None else it for it in self._its)
        return (type(self), args, self._fillvalue)

    def __setstate__(self, state):
        _pickle_deprecated()
        self._fillvalue = state


# ----------------------------------------------------------- combinatorics

class product:
    """product(*iterables, repeat=1) --> product object

Cartesian product of input iterables.  Equivalent to nested for-loops.

For example, product(A, B) returns the same as:  ((x,y) for x in A for y in B).
The leftmost iterators are in the outermost for-loop, so the output tuples
cycle in a manner similar to an odometer (with the rightmost element changing
on every iteration).

To compute the product of an iterable with itself, specify the number
of repetitions with the optional repeat keyword argument. For example,
product(A, repeat=4) means the same as product(A, A, A, A).

product('ab', range(3)) --> ('a',0) ('a',1) ('a',2) ('b',0) ('b',1) ('b',2)
product((0,1), (0,1), (0,1)) --> (0,0,0) (0,0,1) (0,1,0) (0,1,1) (1,0,0) ..."""

    def __new__(cls, *args, **kw):
        repeat = 1
        if kw:
            for k in kw:
                if k != 'repeat':
                    raise TypeError(
                        f"'{k}' is an invalid keyword argument for product()")
            repeat = _ssize(kw['repeat'])
            if repeat < 0:
                raise ValueError("repeat argument cannot be negative")
        nargs = len(args) if repeat else 0
        if repeat and nargs > _MAXSIZE // 8 // repeat:
            raise OverflowError("repeat argument too large")
        pools = tuple([tuple(a) for a in args[:nargs]]) * repeat
        self = _object_new(cls)
        self._pools = pools
        self._indices = [0] * len(pools)
        self._cur = None
        self._stopped = False
        return self

    def __iter__(self):
        return self

    def __next__(self):
        if self._stopped:
            raise StopIteration
        pools = self._pools
        cur = self._cur
        if cur is None:
            cur = []
            for pool in pools:
                if not pool:
                    self._stopped = True
                    raise StopIteration
                cur.append(pool[0])
            self._cur = cur
            return tuple(cur)
        indices = self._indices
        i = len(pools) - 1
        while i >= 0:
            pool = pools[i]
            j = indices[i] + 1
            if j == len(pool):
                indices[i] = 0
                cur[i] = pool[0]
                i -= 1
            else:
                indices[i] = j
                cur[i] = pool[j]
                return tuple(cur)
        self._stopped = True
        raise StopIteration

    def __reduce__(self):
        _pickle_deprecated()
        if self._stopped:
            return (type(self), ((),))
        if self._cur is None:
            return (type(self), self._pools)
        return (type(self), self._pools, tuple(self._indices))

    def __setstate__(self, state):
        _pickle_deprecated()
        pools = self._pools
        n = len(pools)
        if not isinstance(state, tuple) or len(state) != n:
            raise ValueError("invalid arguments")
        indices = []
        for i in range(n):
            index = _as_ssize(state[i])
            size = len(pools[i])
            if size == 0:
                self._stopped = True
                return
            if index < 0:
                index = 0
            elif index > size - 1:
                index = size - 1
            indices.append(index)
        self._indices = indices
        self._cur = [pools[i][indices[i]] for i in range(n)]


class combinations:
    """Return successive r-length combinations of elements in the iterable.

combinations(range(4), 3) --> (0,1,2), (0,1,3), (0,2,3), (1,2,3)"""

    def __new__(cls, iterable, r):
        r = _ssize(r)
        pool = tuple(iterable)
        if r < 0:
            raise ValueError("r must be non-negative")
        self = _object_new(cls)
        self._pool = pool
        self._r = r
        self._indices = list(range(r))
        self._cur = None
        self._stopped = r > len(pool)
        return self

    def __iter__(self):
        return self

    def __next__(self):
        if self._stopped:
            raise StopIteration
        pool = self._pool
        indices = self._indices
        cur = self._cur
        if cur is None:
            cur = self._cur = [pool[i] for i in indices]
            return tuple(cur)
        r = self._r
        top = len(pool) - r
        i = r - 1
        while i >= 0 and indices[i] == i + top:
            i -= 1
        if i < 0:
            self._stopped = True
            raise StopIteration
        index = indices[i] + 1
        indices[i] = index
        cur[i] = pool[index]
        for j in range(i + 1, r):
            index += 1
            indices[j] = index
            cur[j] = pool[index]
        return tuple(cur)

    def __reduce__(self):
        _pickle_deprecated()
        if self._cur is None:
            return (type(self), (self._pool, self._r))
        if self._stopped:
            return (type(self), ((), self._r))
        return (type(self), (self._pool, self._r), tuple(self._indices))

    def __setstate__(self, state):
        _pickle_deprecated()
        r = self._r
        if not isinstance(state, tuple) or len(state) != r:
            raise ValueError("invalid arguments")
        pool = self._pool
        n = len(pool)
        indices = []
        for i in range(r):
            index = _as_ssize(state[i])
            top = i + n - r
            if index > top:
                index = top
            elif index < 0:
                index = 0
            indices.append(index)
        self._indices = indices
        self._cur = [pool[i] for i in indices]


class combinations_with_replacement:
    """Return successive r-length combinations of elements in the iterable allowing individual elements to have successive repeats.

combinations_with_replacement('ABC', 2) --> ('A','A'), ('A','B'), ('A','C'), ('B','B'), ('B','C'), ('C','C')"""

    def __new__(cls, iterable, r):
        r = _ssize(r)
        pool = tuple(iterable)
        if r < 0:
            raise ValueError("r must be non-negative")
        self = _object_new(cls)
        self._pool = pool
        self._r = r
        self._indices = [0] * r
        self._cur = None
        self._stopped = not pool and r > 0
        return self

    def __iter__(self):
        return self

    def __next__(self):
        if self._stopped:
            raise StopIteration
        pool = self._pool
        indices = self._indices
        cur = self._cur
        if cur is None:
            cur = self._cur = [pool[i] for i in indices]
            return tuple(cur)
        last = len(pool) - 1
        r = self._r
        i = r - 1
        while i >= 0 and indices[i] == last:
            i -= 1
        if i < 0:
            self._stopped = True
            raise StopIteration
        index = indices[i] + 1
        elem = pool[index]
        while i < r:
            indices[i] = index
            cur[i] = elem
            i += 1
        return tuple(cur)

    def __reduce__(self):
        _pickle_deprecated()
        if self._cur is None:
            return (type(self), (self._pool, self._r))
        if self._stopped:
            return (type(self), ((), self._r))
        return (type(self), (self._pool, self._r), tuple(self._indices))

    def __setstate__(self, state):
        _pickle_deprecated()
        r = self._r
        if not isinstance(state, tuple) or len(state) != r:
            raise ValueError("invalid arguments")
        pool = self._pool
        n = len(pool)
        indices = []
        for i in range(r):
            index = _as_ssize(state[i])
            if index < 0:
                index = 0
            elif index > n - 1:
                index = n - 1
            indices.append(index)
        self._indices = indices
        self._cur = [pool[i] for i in indices]


class permutations:
    """Return successive r-length permutations of elements in the iterable.

permutations(range(3), 2) --> (0,1), (0,2), (1,0), (1,2), (2,0), (2,1)"""

    def __new__(cls, iterable, r=None):
        pool = tuple(iterable)
        n = len(pool)
        if r is None:
            r = n
        else:
            if not isinstance(r, int):
                raise TypeError("Expected int as r")
            r = _ssize(r)
        if r < 0:
            raise ValueError("r must be non-negative")
        self = _object_new(cls)
        self._pool = pool
        self._r = r
        self._indices = list(range(n))
        self._cycles = list(range(n, n - r, -1))
        self._cur = None
        self._stopped = r > n
        return self

    def __iter__(self):
        return self

    def __next__(self):
        if self._stopped:
            raise StopIteration
        pool = self._pool
        indices = self._indices
        r = self._r
        cur = self._cur
        if cur is None:
            cur = self._cur = [pool[indices[i]] for i in range(r)]
            return tuple(cur)
        n = len(pool)
        if n == 0:
            self._stopped = True
            raise StopIteration
        cycles = self._cycles
        i = r - 1
        while i >= 0:
            c = cycles[i] - 1
            if c == 0:
                index = indices[i]
                del indices[i]
                indices.append(index)
                cycles[i] = n - i
                i -= 1
            else:
                cycles[i] = c
                j = n - c
                indices[i], indices[j] = indices[j], indices[i]
                while i < r:
                    cur[i] = pool[indices[i]]
                    i += 1
                return tuple(cur)
        self._stopped = True
        raise StopIteration

    def __reduce__(self):
        _pickle_deprecated()
        if self._cur is None:
            return (type(self), (self._pool, self._r))
        if self._stopped:
            return (type(self), ((), self._r))
        return (type(self), (self._pool, self._r),
                (tuple(self._indices), tuple(self._cycles)))

    def __setstate__(self, state):
        _pickle_deprecated()
        _state_tuple(state)
        _parse_tuple(state, 2, 2)
        indices, cycles = state
        for i, t in enumerate(state, 1):
            if not isinstance(t, tuple):
                raise TypeError(f"argument {i} must be tuple, "
                                f"not {type(t).__name__}")
        pool = self._pool
        n = len(pool)
        r = self._r
        if len(indices) != n or len(cycles) != r:
            raise ValueError("invalid arguments")
        new_indices = []
        for i in range(n):
            index = _as_ssize(indices[i])
            if index < 0:
                index = 0
            elif index > n - 1:
                index = n - 1
            new_indices.append(index)
        new_cycles = []
        for i in range(r):
            index = _as_ssize(cycles[i])
            if index < 1:
                index = 1
            elif index > n - i:
                index = n - i
            new_cycles.append(index)
        self._indices = new_indices
        self._cycles = new_cycles
        self._cur = [pool[new_indices[i]] for i in range(r)]

