"""_random - the class surface over the MT19937 in src/modules/random.asm.

CPython puts the Mersenne Twister in C for speed, and so does this: the twist
is a 624-iteration loop of shifts and xors, and an interpreter running it one
bytecode at a time cannot be made fast.  What was here before was that loop in
Python, and it cost 47x CPython on `random()` and nearly two seconds per
megabyte of `randbytes` -- which is why test_zlib timed out, since CPython's
check_big_compress_buffer opens with randbytes(10 * 1024 * 1024) whether or
not -M was given.

So the split is the one `_iocore`/`_io` and `_zlibcore`/`zlib` already use.
`_randomcore` holds the state, the twist and the tempering, and takes fixed
positional arguments; this holds the class, the seeding rules, the argument
checking and the state tuple CPython's random.py pickles.

The sequence is the contract.  MT19937 is fully specified and every recorded
seed in CPython's tests depends on the exact stream, so `random()` takes 27
bits from the first word and 26 from the second in that order, `getrandbits`
composes little-endian words with the LAST one narrowed, and the state tuple
is 624 words followed by the cursor.  All of it is checked against CPython's
own output rather than against a distribution.
"""

import _randomcore as _core

_N = 624
_MASK32 = 0xffffffff


class Random:
    """MT19937.  The five methods random.Random actually calls."""

    __slots__ = ("_h", "_gauss_next")

    def __new__(cls, x=None, *args, **kwargs):
        """The state is built HERE, not in __init__.

        CPython's is a C type whose state belongs to the object rather than
        to any Python-level constructor, and random.Random -- which
        subclasses this -- overrides __init__ and calls self.seed(x) without
        ever chaining to ours.  Building the state in __init__ meant that
        subclass had none, and seeding it raised.

        The extra arguments are swallowed for the reason object.__new__
        swallows them: a subclass that overrides __init__ is handed the same
        argument list here, and `class Sub(Random): def __init__(self,
        newarg=None)` then constructs with a keyword this knows nothing
        about.
        """
        self = super().__new__(cls)
        self._h = _core.new()
        self._gauss_next = None
        return self

    def __init__(self, x=None, *args, **kwargs):
        self.seed(x)

    def __del__(self):
        # The handle is an index into a table the module owns, so it has to be
        # given back by hand; nothing else will.
        try:
            h = self._h
        except AttributeError:
            return
        if h is not None:
            self._h = None
            _core.free(h)

    # -- seeding ---------------------------------------------------------
    def seed(self, a=None, version=2):
        """CPython's rule, from _randommodule.c: None means the OS entropy
        source, an exact int is used by absolute value, and anything else is
        seeded from hash(a) cast to an unsigned word.  random.Random.seed does
        the sha512 hashing of str and bytes ITSELF, in Python, and hands this
        an int -- so the reproducible path is the int one, and it is
        bit-for-bit CPython's."""
        if a is None:
            try:
                import posix
                a = int.from_bytes(posix.urandom(32), "big")
            except Exception:
                import time
                a = int(time.time() * 1000000)
        elif isinstance(a, int):
            # int's own, not abs(): a subclass whose __abs__ answers None
            # left the key empty, and CPython asks the int for the same
            # reason (bpo-31478).
            a = int.__abs__(a)
        else:
            a = hash(a) & 0xffffffffffffffff

        key = []
        if a == 0:
            key = [0]
        while a:
            key.append(a & _MASK32)
            a >>= 32
        _core.seed_words(self._h, key)

    # -- generation ------------------------------------------------------
    def random(self):
        """A double in [0, 1), from 53 bits."""
        return _core.random(self._h)

    def getrandbits(self, k):
        if not isinstance(k, int):
            # CPython's argument clinic takes an `int k`, so the refusal is
            # __index__'s wording rather than one of our own.
            try:
                k = k.__index__()
            except AttributeError:
                raise TypeError(
                    "'%s' object cannot be interpreted as an integer"
                    % (type(k).__name__,)) from None
        if k < 0:
            raise ValueError("number of bits must be non-negative")
        if k <= 32:
            return _core.bits(self._h, k)
        # One word per 32 bits, least significant first, last one narrowed --
        # assembled as bytes and imported in one step rather than shifted
        # together here, which is what makes randbytes() of a megabyte cheap.
        return int.from_bytes(_core.words(self._h, k), "little")

    # -- the state tuple CPython's random.py pickles ----------------------
    def getstate(self):
        raw = _core.getstate(self._h)
        return tuple([int.from_bytes(raw[i:i + 4], "little")
                      for i in range(0, len(raw), 4)])

    def setstate(self, state):
        if not isinstance(state, tuple):
            raise TypeError("state vector must be a tuple")
        if len(state) != _N + 1:
            raise ValueError("state vector is the wrong size")
        mti = int(state[_N])
        if mti < 0 or mti > _N:
            raise ValueError("invalid state")
        raw = b"".join([(int(v) & _MASK32).to_bytes(4, "little")
                        for v in state[:_N]])
        _core.setstate(self._h, raw + mti.to_bytes(4, "little"))
