"""The four sharp corrections in the old bug list's tail, each with its own repro.

None of them is about a missing feature: every one is a message or an
attribute that answered something CPython does not, in code that ran.

  * an unbound `super` was not a descriptor, so the idiom
    `C._C__super = super(C)` then `self.__super.meth()` read the unbound
    super straight back and every name on it missed;
  * `super(C, proxy)` searched the MRO of the class it was WRITTEN with
    rather than the one the proxy declares, and reported the written one as
    `__self_class__`;
  * `o.__dict__ = d` added a key spelled '__dict__' and left the real dict
    alone, and `o.__weakref__ = x` quietly succeeded;
  * an AttributeError carried neither `.name` nor `.obj`, which is what the
    "Did you mean" machinery and a __getattr__ hook's own miss test read.
"""


# --- an unbound super is a descriptor ---------------------------------------

class B:
    def meth(self, a):
        return "B(%s)" % a


class C(B):
    def meth(self, a):
        return "C(%s)" % self.__super.meth(a)


C._C__super = super(C)


def test_unbound_super_binds():
    assert hasattr(super(C), '__get__')
    assert C().meth(1) == "C(B(1))"
    # Bound, or bound to nothing, is the identity.
    s = super(C)
    assert s.__get__(None, C) is s
    bound = super(C, C())
    assert bound.__get__(C(), C) is bound
    # And the binding really is a supercheck, not a blind copy.
    assert s.__get__(C(), C).__self_class__ is C


# --- a proxy's declared class is the one searched ---------------------------

class X(B):
    def meth(self, a):
        return "X(%s)" % a


class E(C, X):
    pass


class Proxy:
    def __init__(self, o):
        self.__dict__['_o'] = o

    @property
    def __class__(self):
        return type(self._o)

    def __getattr__(self, n):
        return getattr(self._o, n)


def test_proxy_super_uses_the_declared_mro():
    p = Proxy(E())
    # E's MRO is E, C, X, B, object, so the search after C reaches X.
    def inside():                       # a function, so the opcode specialises
        return super(C, p).meth(1), super(C, p).__self_class__
    assert inside() == ("X(1)", E)
    # ...and the unspecialised path at module level agrees.
    assert super(C, p).meth(1) == "X(1)"
    assert super(C, p).__self__ is p
    try:
        super(C, p).nosuchname
    except AttributeError as e:
        assert "nosuchname" in str(e), e
    else:
        raise AssertionError("no AttributeError")


# --- __dict__ and __weakref__ are not instance-dict keys --------------------

class Plain:
    pass


class Slotted:
    __slots__ = ('x',)


def test_dict_assignment_replaces_the_dict():
    o = Plain()
    o.keep = 1
    o.__dict__ = {'x': 5}
    assert o.x == 5
    assert o.__dict__ == {'x': 5}
    assert not hasattr(o, 'keep')
    # A delete clears the slot; the next read builds a fresh empty one.
    del o.__dict__
    assert o.__dict__ == {}
    # A dict subclass is accepted, anything else is not.
    class D(dict):
        pass
    o.__dict__ = D(k=1)
    assert o.k == 1
    try:
        o.__dict__ = 5
    except TypeError as e:
        assert str(e) == "__dict__ must be set to a dictionary, not a 'int'", e
    else:
        raise AssertionError("no TypeError")
    # setattr() takes the same road.
    setattr(o, '__dict__', {'z': 9})
    assert o.z == 9


def test_weakref_is_not_writable():
    o = Plain()
    for act in (lambda: setattr(o, '__weakref__', 5),
                lambda: delattr(o, '__weakref__')):
        try:
            act()
        except AttributeError as e:
            assert str(e) == ("attribute '__weakref__' of 'Plain' objects "
                              "is not writable"), e
        else:
            raise AssertionError("no AttributeError")


def test_slotted_has_neither():
    s = Slotted()
    for name in ('__dict__', '__weakref__'):
        try:
            setattr(s, name, {})
        except AttributeError as e:
            assert str(e) == ("'Slotted' object has no attribute %r" % name), e
        else:
            raise AssertionError("no AttributeError for " + name)


# --- AttributeError.name and .obj -------------------------------------------

class Hook:
    def __getattr__(self, n):
        raise AttributeError("custom %s" % n)


class Named:
    def __getattr__(self, n):
        raise AttributeError("mine", name='given', obj=None)


def test_attribute_error_context():
    o = Plain()
    try:
        o.nope
    except AttributeError as e:
        assert e.name == 'nope', e.name
        assert e.obj is o
    # A class and a module take the same road.
    try:
        Plain.nope
    except AttributeError as e:
        assert e.name == 'nope' and e.obj is Plain
    import sys
    try:
        sys.nope
    except AttributeError as e:
        assert e.name == 'nope' and e.obj is sys
    # An immediate is an object like any other.
    try:
        (5).nope
    except AttributeError as e:
        assert e.name == 'nope' and e.obj == 5


def test_hook_raised_error_gets_the_context():
    h = Hook()
    try:
        h.zz
    except AttributeError as e:
        assert str(e) == "custom zz"
        assert e.name == 'zz', e.name
        assert e.obj is h
    # ...but a hook that named one of its own keeps it.
    try:
        Named().zz
    except AttributeError as e:
        assert e.name == 'given', e.name


def test_a_store_fills_in_neither():
    # CPython's set_attribute_error_context runs only on the generic GET.
    o = Plain()
    try:
        del o.zzz
    except AttributeError as e:
        assert e.name is None, e.name
    # An unset name reads as None rather than raising.
    assert AttributeError('x').name is None
    assert AttributeError('x').obj is None
    assert ImportError('x').name is None
    assert ImportError('x').path is None


# --- .obj keeps the receiver alive, which changes what dies when -------------

class Finalized:
    """A class with a __del__, which is what made `.obj` dangerous.

    Storing the receiver on the exception means the exception's teardown is
    what finally releases it -- so an arbitrary `__del__` runs inside
    `exc_dealloc`, inside `POP_EXCEPT`'s release of handled_exception.  That
    global still pointed at the object being freed, and entering the
    finalizer's frame swapped it into PyFrame.exc_state and back, counting it
    both ways: 0 -> 1 -> 0, and a second obj_dealloc on a block already gone.
    """

    closed = []

    def __del__(self):
        Finalized.closed.append(1)


def test_a_finalizer_on_the_receiver():
    del Finalized.closed[:]
    try:
        Finalized().nosuch          # the only reference is the exception's
    except AttributeError as e:
        assert type(e.obj) is Finalized
    assert Finalized.closed == [1], Finalized.closed
    # An _io object is the shape this was found on: every one of them has a
    # __del__ through IOBase.
    import io
    for make in (io.BytesIO, io.StringIO):
        try:
            make().nosuch
        except AttributeError:
            pass
    # A cycle through the exception's own dict has to be collectable, which
    # needs exc_traverse to report that edge.
    import gc

    class Holder:
        pass

    def build():
        h = Holder()
        try:
            h.nosuch
        except AttributeError as e:
            h.err = e               # exception -> dict -> h -> dict -> exception
    build()
    gc.collect()


# --- the callee names itself in a starred call ------------------------------

def test_star_refusal_names_the_callee():
    def g(*a):
        return a
    try:
        g(*5)
    except TypeError as e:
        assert str(e).endswith("g() argument after * must be an iterable, "
                               "not int"), e
    else:
        raise AssertionError("no TypeError")
    # A lone `*x` is a bare CALL_FUNCTION_EX, so every iterable still arrives.
    assert g(*[1, 2]) == (1, 2)
    assert g(*(3,)) == (3,)
    assert g(*"ab") == ('a', 'b')
    assert g(*range(2)) == (0, 1)
    assert g(*{'k': 1}) == ('k',)

    class ByIndex:
        def __getitem__(self, i):
            if i > 1:
                raise IndexError
            return i
    assert g(*ByIndex()) == (0, 1)

    # More than one star, or a positional beside it, keeps the anonymous
    # wording -- CPython builds a list there and the list is what refuses.
    try:
        g(*5, *6)
    except TypeError as e:
        assert str(e) == "Value after * must be an iterable, not int", e


# --- what a starred-call refusal owes the value stack ------------------------

def test_star_refusal_releases_the_sequence():
    """The refusal raises from inside the handler, and DISPATCH's saved stack
    top -- set before the three operands came off -- is what the unwinder
    releases them from.  Republishing it at the raise pointed the unwinder
    BELOW them and leaked the starred sequence on every call."""
    import gc

    class NotIter:
        pass

    def f(*a):
        pass

    gc.collect()
    for _ in range(200):
        try:
            f(*NotIter())
        except TypeError:
            pass
    gc.collect()
    # The instances are unreachable, so a collection must account for all of
    # them; a leaked reference would keep them alive.
    assert sum(1 for o in gc.get_objects()
               if type(o).__name__ == "NotIter") == 0


# --- print() is an I/O operation too -----------------------------------------

def test_print_to_a_closed_stream():
    """close() shuts the descriptor; print() went on appending to the closed
    object's buffer and the failure surfaced at exit -- or, once the fd had
    been reused, as text written into an unrelated file."""
    import os
    import sys
    # sys.stdout at start-up is the built-in stream object, which is the one
    # print() reaches through fileobj_emit -- a StringIO takes a different
    # road.  Forking is the only way to close the real one and still be able
    # to report what happened.
    read_fd, write_fd = os.pipe()
    pid = os.fork()
    if pid == 0:
        try:
            os.close(read_fd)
            sys.stdout.close()
            try:
                print("x")
            except ValueError as e:
                os.write(write_fd, str(e).encode())
            else:
                os.write(write_fd, b"NO RAISE")
        finally:
            os._exit(0)
    os.close(write_fd)
    got = b""
    while True:
        chunk = os.read(read_fd, 256)
        if not chunk:
            break
        got += chunk
    os.close(read_fd)
    os.waitpid(pid, 0)
    assert got.startswith(b"I/O operation on closed file"), got


# --- OSError's reduction ----------------------------------------------------

def test_oserror_reduce():
    import errno
    import pickle
    e = OSError(errno.ENOENT, "No such file", "f.txt")
    # The filename goes back INTO the arguments; args itself stays a 2-tuple.
    assert e.args == (errno.ENOENT, "No such file")
    assert e.__reduce__() == (FileNotFoundError,
                              (errno.ENOENT, "No such file", "f.txt"))
    # Two filenames need the Windows-only winerror as a None placeholder.
    e2 = OSError(errno.ENOENT, "No such file", "f.txt", None, "g.txt")
    assert e2.__reduce__() == (FileNotFoundError,
                               (errno.ENOENT, "No such file", "f.txt",
                                None, "g.txt"))
    # No filename: the arguments stand as they are, and there is still no
    # state -- the four named attributes are not part of one.
    assert OSError(1, "x").__reduce__() == (PermissionError, (1, "x"))
    assert OSError().__reduce__() == (OSError, ())
    assert OSError("plain").__reduce__() == (OSError, ("plain",))
    # An attribute a program set IS a state.
    e3 = OSError(2, "x", "f")
    e3.extra = 7
    red = e3.__reduce__()
    assert len(red) == 3 and red[2] == {'extra': 7}, red
    assert pickle.loads(pickle.dumps(e3)).extra == 7
    back = pickle.loads(pickle.dumps(e))
    assert (back.errno, back.strerror, back.filename) == (
        errno.ENOENT, "No such file", "f.txt")


for fn in (test_unbound_super_binds,
           test_proxy_super_uses_the_declared_mro,
           test_dict_assignment_replaces_the_dict,
           test_weakref_is_not_writable,
           test_slotted_has_neither,
           test_attribute_error_context,
           test_hook_raised_error_gets_the_context,
           test_a_store_fills_in_neither,
           test_a_finalizer_on_the_receiver,
           test_star_refusal_names_the_callee,
           test_star_refusal_releases_the_sequence,
           test_print_to_a_closed_stream,
           test_oserror_reduce):
    fn()
    print(fn.__name__, 'ok')
print('OK')
