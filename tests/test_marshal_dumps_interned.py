# marshal.dumps writes an interned str with the INTERNED type codes, as
# CPython's does ('Z' / 'A' / 't', with FLAG_REF), so marshal.loads hands
# back an interned string.  A .pyc apython writes itself goes through
# dumps, and importlib reads it back with loads: written without the flag,
# every identifier-like constant in a cached module stopped being the same
# object as the literal elsewhere.
import marshal
import sys

names = ["hello_world", "abc_d", "x" * 300, "_"]
for n in names:
    s = sys.intern(n)
    data = marshal.dumps(s)
    back = marshal.loads(data)
    print(repr(n[:12]), data[:1] in (b"Z", b"\xda", b"A", b"\xc1", b"t", b"\xf4"),
          back is s)

# Not interned: a string built at run time stays an ordinary string.
plain = "".join(["not ", "interned", "!"])
print(marshal.dumps(plain)[:1] in (b"z", b"\xfa", b"a", b"\xe1", b"u", b"\xf5"))

# Through a code object, which is how a .pyc gets them.
code = compile('X = "ident_like"\nY = "has space"', "m", "exec")
loaded = marshal.loads(marshal.dumps(code))
ns = {}
exec(loaded, ns)
print(ns["X"] is sys.intern("ident_like"))
