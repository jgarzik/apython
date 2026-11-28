# _collections - the C accelerator module CPython's collections/__init__.py
# reaches for.
#
# It opens with `from _collections import deque` / `defaultdict` in a
# try/except ImportError and exports both from __all__ regardless -- so with
# no _collections at all, `from collections import deque` was an ImportError
# rather than a slower deque.  That blocked contextlib, typing, shlex, glob,
# webbrowser, bdb and the rest of their dependents from importing at all.
#
# So the implementations live here and collections/__init__.py imports them
# back, which is the arrangement CPython uses.  deque keeps a live WINDOW in
# a list rather than inserting at index 0, so appendleft and popleft are O(1)
# amortised as CPython's block-linked list makes them; every observable
# answer matches for a finite iterable.
#
# _tuplegetter and _count_elements are deliberately absent.  CPython's
# collections has a pure-Python fallback for each and takes it when the
# import fails, so supplying them would replace a working fallback with a
# slower copy of it.

__all__ = ["deque", "defaultdict"]

from _operator import index as _index
import _thread
from types import GenericAlias as _GenericAlias

# OrderedDict is deliberately NOT here.  CPython's collections/__init__.py
# defines the complete pure-Python class and only *then* tries to override it
# from _collections -- so exporting an `OrderedDict = dict` alias from here
# shadowed the real one everywhere a real stdlib was on the path.  deque and
# defaultdict have no such fallback there and must stay.


class defaultdict(dict):
    """defaultdict(default_factory=None, /, [...]) --> dict with a default.

    A real dict subclass, which is not a detail: isinstance(d, dict) is what
    json, pprint, copy and a great deal of ordinary code branch on, and every
    dict method this class does not mention -- setdefault, clear, popitem,
    fromkeys, ==, reversed -- is inherited rather than forwarded.  It used to
    be a plain class holding a dict in self._data, and CPython's own
    test_defaultdict reported 988 errors against it.

    __missing__ is the whole of the default behaviour, and the interpreter
    already consults it on any dict subclass: dict_subscript checks the type
    and calls it, so `d[k]` reaches this without a __getitem__ here.  Defining
    one would be worse than redundant -- it would force a mapping slot table
    of this class's own and lose the direct read.
    """

    __slots__ = ("default_factory",)

    def __init__(self, default_factory=None, /, *args, **kwargs):
        if default_factory is not None and not callable(default_factory):
            raise TypeError("first argument must be callable or None")
        super().__init__(*args, **kwargs)
        self.default_factory = default_factory

    def __missing__(self, key):
        if self.default_factory is None:
            raise KeyError(key)
        value = self.default_factory()
        self[key] = value
        return value

    def __repr__(self):
        # dict.__repr__ carries the recursion guard, so a dict that contains
        # itself prints {...} rather than running out of stack.
        return "%s(%r, %s)" % (type(self).__name__, self.default_factory,
                               dict.__repr__(self))

    def copy(self):
        return type(self)(self.default_factory, self)

    __copy__ = copy

    def __reduce__(self):
        args = () if self.default_factory is None else (self.default_factory,)
        return type(self), args, None, None, iter(self.items())

    # The three merge operators answer a defaultdict, keeping the factory, as
    # CPython's do -- dict's own would hand back a plain dict.
    def __or__(self, other):
        if not isinstance(other, dict):
            return NotImplemented
        new = self.copy()
        new.update(other)
        return new

    def __ror__(self, other):
        if not isinstance(other, dict):
            return NotImplemented
        new = type(self)(self.default_factory, other)
        new.update(self)
        return new

    def __ior__(self, other):
        self.update(other)
        return self


class deque:
    """deque([iterable[, maxlen]]) --> deque object

    A list with a live WINDOW in it: the elements are _items[_head:_tail] and
    the two ends move rather than the contents.  That is what makes
    appendleft and popleft O(1) amortised, which is the whole point of the
    type -- the previous version inserted at and deleted from index 0, so
    every one of them was O(n) and any breadth-first search written on a
    deque was quadratic.

    Room at the front is reserved in doubling chunks and reclaimed when the
    dead prefix grows past half the window, so the amortised cost of a
    million appendlefts is linear.  CPython's is a block-linked list; the
    observable answers are the same.

    __slots__ matters as much as the algorithm: without it every instance
    carried a __dict__, and a subclass declaring `__slots__ = ("x", "y",
    "__dict__")` -- which CPython's own test_deque does -- was refused with
    "__dict__ slot disallowed: we already got one".
    """

    __slots__ = ("_items", "_head", "_tail", "_maxlen", "_lock")

    # CPython's C deque has tp_name "collections.deque" even though the type
    # lives in _collections, and repr(), __class_getitem__ and pickle all
    # show it.
    __module__ = "collections"

    # The smallest front reservation, and the dead-prefix ratio that triggers
    # a compaction.  Both are arbitrary; what matters is that the reservation
    # doubles, so the work is amortised.
    _MINSPARE = 8

    def __new__(cls, *args, **kwargs):
        self = object.__new__(cls)
        self._lock = _thread.allocate_lock()
        self._items = []
        self._head = 0
        self._tail = 0
        self._maxlen = None
        return self

    def __init__(self, iterable=(), maxlen=None):
        if maxlen is not None:
            maxlen = _index(maxlen)
            if maxlen < 0:
                raise ValueError("maxlen must be non-negative")
        with self._lock:
            self._maxlen = maxlen
            self._items = []
            self._head = 0
            self._tail = 0
        self.extend(iterable)

    # --- the window (caller holds self._lock) --------------------------
    def _compact(self):
        """Drop the dead prefix and suffix, keeping the live window."""
        self._items = self._items[self._head:self._tail]
        self._tail -= self._head
        self._head = 0

    def _reserve_front(self):
        """Make room below _head, in a doubling chunk."""
        n = self._tail - self._head
        spare = n if n > self._MINSPARE else self._MINSPARE
        self._items[:0] = [None] * spare
        self._head += spare
        self._tail += spare

    def _popleft_locked(self):
        x = self._items[self._head]
        self._items[self._head] = None
        self._head += 1
        if self._head > self._MINSPARE and self._head * 2 > len(self._items):
            self._compact()
        return x

    def _pop_locked(self):
        self._tail -= 1
        x = self._items[self._tail]
        self._items[self._tail] = None      # drop the reference
        return x

    @property
    def maxlen(self):
        return self._maxlen

    # --- adding --------------------------------------------------------
    def append(self, x):
        with self._lock:
            if self._maxlen == 0:
                return
            if self._tail == len(self._items):
                self._items.append(x)
            else:
                self._items[self._tail] = x
            self._tail += 1
            if self._maxlen is not None and self._tail - self._head > self._maxlen:
                self._popleft_locked()

    def appendleft(self, x):
        with self._lock:
            if self._maxlen == 0:
                return
            if self._head == 0:
                self._reserve_front()
            self._head -= 1
            self._items[self._head] = x
            if self._maxlen is not None and self._tail - self._head > self._maxlen:
                self._pop_locked()

    def extend(self, iterable):
        if iterable is self:
            iterable = self._as_list()
        for x in iterable:
            self.append(x)

    def extendleft(self, iterable):
        if iterable is self:
            iterable = self._as_list()
        for x in iterable:
            self.appendleft(x)

    def insert(self, i, x):
        i = _index(i)
        with self._lock:
            n = self._tail - self._head
            if self._maxlen is not None and n >= self._maxlen:
                raise IndexError("deque already at its maximum size")
            if i < 0:
                i += n
                if i < 0:
                    i = 0
            elif i > n:
                i = n
            self._compact()
            self._items.insert(i, x)
            self._tail += 1

    # --- removing ------------------------------------------------------
    def pop(self):
        with self._lock:
            if self._head == self._tail:
                raise IndexError("pop from an empty deque")
            return self._pop_locked()

    def popleft(self):
        with self._lock:
            if self._head == self._tail:
                raise IndexError("pop from an empty deque")
            return self._popleft_locked()

    def clear(self):
        with self._lock:
            self._items = []
            self._head = 0
            self._tail = 0

    def remove(self, x):
        snap = self._as_list()
        for i in range(len(snap)):
            if snap[i] == x:
                del self[i]
                return
        raise ValueError(repr(x) + " is not in deque")

    # --- reading -------------------------------------------------------
    def count(self, x):
        c = 0
        for item in self._as_list():
            if item == x:
                c += 1
        return c

    def index(self, x, start=0, stop=None):
        start = _index(start)
        if stop is not None:
            stop = _index(stop)
        snap = self._as_list()
        n = len(snap)
        if start < 0:
            start = max(0, start + n)
        if stop is None:
            stop = n
        elif stop < 0:
            stop += n
        if stop > n:
            stop = n
        for i in range(start, stop):
            if snap[i] == x:
                return i
        raise ValueError(repr(x) + " is not in deque")

    def reverse(self):
        with self._lock:
            i, j = self._head, self._tail - 1
            items = self._items
            while i < j:
                items[i], items[j] = items[j], items[i]
                i += 1
                j -= 1

    def rotate(self, n=1):
        n = _index(n)
        with self._lock:
            size = self._tail - self._head
            if size == 0 or n == 0:
                return
            n = n % size
            if not n:
                return
            self._compact()
            self._items = self._items[-n:] + self._items[:-n]

    def copy(self):
        return type(self)(self._as_list(), self._maxlen)

    __copy__ = copy

    def __reduce__(self):
        if self._maxlen is None:
            return (type(self), (self._as_list(),))
        return (type(self), (self._as_list(), self._maxlen))

    def __class_getitem__(cls, item):
        return _GenericAlias(cls, item)

    def _index_check_locked(self, i):
        n = self._tail - self._head
        if i < 0:
            i += n
        if i < 0 or i >= n:
            raise IndexError("deque index out of range")
        return self._head + i

    def __len__(self):
        with self._lock:
            return self._tail - self._head

    def __iter__(self):
        # A copy of the window, so mutating the deque while iterating cannot
        # walk off the end -- and not list(self), which would call this.
        return iter(self._as_list())

    def __reversed__(self):
        return iter(self._as_list()[::-1])

    def __getitem__(self, i):
        i = _index(i)
        with self._lock:
            return self._items[self._index_check_locked(i)]

    def __setitem__(self, i, v):
        i = _index(i)
        with self._lock:
            self._items[self._index_check_locked(i)] = v

    def __delitem__(self, i):
        i = _index(i)
        with self._lock:
            idx = self._index_check_locked(i) - self._head
            self._compact()
            del self._items[idx]
            self._tail -= 1

    def __contains__(self, x):
        for item in self._as_list():
            if item == x:
                return True
        return False

    def __bool__(self):
        with self._lock:
            return self._tail != self._head

    # --- comparison ----------------------------------------------------
    def _as_list(self):
        with self._lock:
            return self._items[self._head:self._tail]

    def __eq__(self, other):
        if isinstance(other, deque):
            return self._as_list() == other._as_list()
        return NotImplemented

    def __ne__(self, other):
        r = self.__eq__(other)
        if r is NotImplemented:
            return r
        return not r

    def __lt__(self, other):
        if isinstance(other, deque):
            return self._as_list() < other._as_list()
        return NotImplemented

    def __le__(self, other):
        if isinstance(other, deque):
            return self._as_list() <= other._as_list()
        return NotImplemented

    def __gt__(self, other):
        if isinstance(other, deque):
            return self._as_list() > other._as_list()
        return NotImplemented

    def __ge__(self, other):
        if isinstance(other, deque):
            return self._as_list() >= other._as_list()
        return NotImplemented

    __hash__ = None

    # --- arithmetic ----------------------------------------------------
    def __add__(self, other):
        if not isinstance(other, deque):
            return NotImplemented
        return type(self)(self._as_list() + other._as_list(), self._maxlen)

    def __iadd__(self, other):
        self.extend(other)
        return self

    def __mul__(self, n):
        n = _index(n)
        return type(self)(self._as_list() * n, self._maxlen)

    __rmul__ = __mul__

    def __imul__(self, n):
        n = _index(n)
        if n <= 0:
            self.clear()
            return self
        if n > 1:
            base = self._as_list()
            for _ in range(n - 1):
                self.extend(base)
        return self

    def __repr__(self):
        body = repr(self._as_list())
        if self._maxlen is None:
            return type(self).__name__ + "(" + body + ")"
        return (type(self).__name__ + "(" + body + ", maxlen="
                + repr(self._maxlen) + ")")
