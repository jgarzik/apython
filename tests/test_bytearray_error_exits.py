# Every refusal a bytearray makes.
#
# Its slots and its mutators used to leave non-locally on an error.  They
# return it now: the exception is the right one, the bytearray is what it
# was, and a refusal made while a memoryview is out leaves the view usable
# and the export count where it was -- the bytearray can be resized again
# the moment the view is released.
class Boom(Exception):
    pass


class IndexRaises:
    def __index__(self):
        raise Boom("index")


class IterRaises:
    def __iter__(self):
        raise Boom("iter")


def gen_raises():
    yield 1
    raise Boom("gen")


def check(label, fn):
    try:
        r = fn()
    except Exception as e:
        print("%-32s %s%s" % (label, type(e).__name__,
                              ": " + str(e) if isinstance(e, Boom) else ""))
    else:
        if isinstance(r, bytearray):
            r = bytes(r)
        print("%-32s %r" % (label, r))


def fresh():
    return bytearray(b"abcd")


def setitem(key, value):
    b = fresh()
    b[key] = value
    return b


def delitem(key):
    b = fresh()
    del b[key]
    return b


def call(name, *args):
    b = fresh()
    r = getattr(b, name)(*args)
    return (r, bytes(b))


cases = [
    ("b[9]", lambda: fresh()[9]),
    ("b[-9]", lambda: fresh()[-9]),
    ("b['a']", lambda: fresh()["a"]),
    ("b[1.5]", lambda: fresh()[1.5]),
    ("b[raises]", lambda: fresh()[IndexRaises()]),
    ("b[2**70]", lambda: fresh()[2 ** 70]),
    ("b[raises:]", lambda: fresh()[IndexRaises():]),
    ("b[::0]", lambda: fresh()[::0]),
    ("b.__getitem__(9)", lambda: fresh().__getitem__(9)),
    ("b[9] = 1", lambda: setitem(9, 1)),
    ("b['a'] = 1", lambda: setitem("a", 1)),
    ("b[raises] = 1", lambda: setitem(IndexRaises(), 1)),
    ("b[0] = 256", lambda: setitem(0, 256)),
    ("b[0] = -1", lambda: setitem(0, -1)),
    ("b[0] = 'a'", lambda: setitem(0, "a")),
    ("b[0] = raises", lambda: setitem(0, IndexRaises())),
    ("b[raises:] = b''", lambda: setitem(slice(IndexRaises(), None), b"")),
    ("b[::0] = b''", lambda: setitem(slice(None, None, 0), b"")),
    ("b[0:1] = 'a'", lambda: setitem(slice(0, 1), "a")),
    ("b[0:1] = [256]", lambda: setitem(slice(0, 1), [256])),
    ("b[0:1] = ['a']", lambda: setitem(slice(0, 1), ["a"])),
    ("b[0:1] = iter raises", lambda: setitem(slice(0, 1), IterRaises())),
    ("b[0:1] = gen raises", lambda: setitem(slice(0, 1), gen_raises())),
    ("b[0:1] = None", lambda: setitem(slice(0, 1), None)),
    ("b[::2] = b'x'", lambda: setitem(slice(None, None, 2), b"x")),
    ("b[::2] = b'xyz'", lambda: setitem(slice(None, None, 2), b"xyz")),
    ("b[::2] = gen raises", lambda: setitem(slice(None, None, 2), gen_raises())),
    ("b.__setitem__(9, 1)", lambda: fresh().__setitem__(9, 1)),
    ("del b[9]", lambda: delitem(9)),
    ("del b['a']", lambda: delitem("a")),
    ("del b[raises]", lambda: delitem(IndexRaises())),
    ("del b[raises:]", lambda: delitem(slice(IndexRaises(), None))),
    ("b.__delitem__(9)", lambda: fresh().__delitem__(9)),
    ("256 in b", lambda: 256 in fresh()),
    ("-1 in b", lambda: -1 in fresh()),
    ("2**70 in b", lambda: 2 ** 70 in fresh()),
    ("'a' in b", lambda: "a" in fresh()),
    ("None in b", lambda: None in fresh()),
    ("1.5 in b", lambda: 1.5 in fresh()),
    ("b.__contains__('a')", lambda: fresh().__contains__("a")),
    ("append(256)", lambda: call("append", 256)),
    ("append('a')", lambda: call("append", "a")),
    ("append(raises)", lambda: call("append", IndexRaises())),
    ("extend('a')", lambda: call("extend", "a")),
    ("extend([256])", lambda: call("extend", [256])),
    ("extend(gen raises)", lambda: call("extend", gen_raises())),
    ("insert('a', 1)", lambda: call("insert", "a", 1)),
    ("insert(raises, 1)", lambda: call("insert", IndexRaises(), 1)),
    ("insert(0, 256)", lambda: call("insert", 0, 256)),
    ("insert(0, raises)", lambda: call("insert", 0, IndexRaises())),
    ("pop(9)", lambda: call("pop", 9)),
    ("pop(-9)", lambda: call("pop", -9)),
    ("pop('a')", lambda: call("pop", "a")),
    ("pop(raises)", lambda: call("pop", IndexRaises())),
    ("empty pop()", lambda: bytearray().pop()),
    ("remove(120)", lambda: call("remove", 120)),
    ("remove(256)", lambda: call("remove", 256)),
    ("remove('a')", lambda: call("remove", "a")),
    ("remove(raises)", lambda: call("remove", IndexRaises())),
    ("b + 'a'", lambda: fresh() + "a"),
    ("b + 5", lambda: fresh() + 5),
    ("b += 'a'", lambda: fresh().__iadd__("a")),
    ("b += 5", lambda: fresh().__iadd__(5)),
    ("b * 'a'", lambda: fresh() * "a"),
    ("b * raises", lambda: fresh() * IndexRaises()),
    ("b * 2**40", lambda: fresh() * 2 ** 40),
    ("b * 2**64", lambda: fresh() * 2 ** 64),
    ("b *= raises", lambda: fresh().__imul__(IndexRaises())),
    ("b *= 2**40", lambda: fresh().__imul__(2 ** 40)),
    ("b *= 2**64", lambda: fresh().__imul__(2 ** 64)),
]
for label, fn in cases:
    for _ in range(2):
        check(label, fn)

# With a view out, anything that would change the length is refused -- and
# nothing has moved under the view when it is.
b = bytearray(b"abcd")
m = memoryview(b)
exported = [
    ("pop()", lambda: b.pop()),
    ("pop(0)", lambda: b.pop(0)),
    ("remove(97)", lambda: b.remove(97)),
    ("append(1)", lambda: b.append(1)),
    ("extend(b'x')", lambda: b.extend(b"x")),
    ("insert(0, 1)", lambda: b.insert(0, 1)),
    ("clear()", lambda: b.clear()),
    ("del b[0]", lambda: b.__delitem__(0)),
    ("del b[0:2]", lambda: b.__delitem__(slice(0, 2))),
    ("del b[::2]", lambda: b.__delitem__(slice(None, None, 2))),
    ("b[0:1] = b'xy'", lambda: b.__setitem__(slice(0, 1), b"xy")),
    ("b[0:2] = b''", lambda: b.__setitem__(slice(0, 2), b"")),
    ("b += b'x'", lambda: b.__iadd__(b"x")),
    ("b *= 2", lambda: b.__imul__(2)),
    ("b *= 0", lambda: b.__imul__(0)),
    ("b *= 1", lambda: b.__imul__(1)),
    ("b *= raises", lambda: b.__imul__(IndexRaises())),
    ("b[0:1] = b'X' (same size)", lambda: b.__setitem__(slice(0, 1), b"X")),
    ("b[1] = 66", lambda: b.__setitem__(1, 66)),
    ("b[0:1] = gen raises", lambda: b.__setitem__(slice(0, 1), gen_raises())),
]
for label, fn in exported:
    check("exported: " + label, fn)
    print("   ", bytes(b), bytes(m))
m.release()
check("released: b *= 2", lambda: b.__imul__(2))
check("released: pop()", lambda: b.pop())
check("released: del b[0:2]", lambda: (b.__delitem__(slice(0, 2)), bytes(b))[1])


# The count's __index__ is Python, and may take a view of the very bytearray
# being repeated: the refusal has to see it.
class TakesView:
    def __init__(self, target, n):
        self.target = target
        self.n = n

    def __index__(self):
        self.view = memoryview(self.target)
        return self.n


for n in (0, 1, 3):
    b = bytearray(b"ab")
    t = TakesView(b, n)
    check("b *= takes-view(%d)" % n, lambda: b.__imul__(t))
    print("   ", bytes(b), bytes(t.view))
    t.view.release()


# The value's __index__ may shorten the bytearray after the index was
# checked against it.
class Shortens:
    def __init__(self, target):
        self.target = target

    def __index__(self):
        self.target.clear()
        return 65


b = bytearray(b"abcd")
check("b[3] = shortens", lambda: b.__setitem__(3, Shortens(b)))
print("   ", bytes(b))
