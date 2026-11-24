# LOAD_GLOBAL's inline cache, against the two things its guard used to miss:
# one code object run in two namespaces, and a namespace too big for the
# sixteen bits the cache keeps of an index.  Every read goes through ONE
# call site per function so the site is warm when it meets the second dict.
import types

code = compile('def f():\n    return x\n', 's', 'exec')

a = {}; exec(code, a); a['x'] = 'A'
b = {}; b['x'] = 'B'; exec(code, b)
print([(a['f'](), b['f']()) for _ in range(4)])

fa = a['f']
fb = types.FunctionType(fa.__code__, {'y': 1, 'x': 'B2'})
fc = types.FunctionType(fa.__code__, {'x': 'C'})
print([(fa(), fb(), fc()) for _ in range(4)])

# A smaller namespace than the one the site warmed on: the cached index is
# past the end of its table.
big = {'p%d' % i: i for i in range(50)}
big['x'] = 'BIG'
fbig = types.FunctionType(fa.__code__, big)
print([fbig() for _ in range(4)], [fc() for _ in range(4)], [fbig() for _ in range(2)])

# Builtins: a namespace that shadows one, sharing a site with one that does not.
bcode = compile('def g(v):\n    return len(v)\n', 's', 'exec')
n1 = {}; exec(bcode, n1)
n2 = {}; exec(bcode, n2); n2['len'] = lambda v: 'shadowed'
print([(n1['g']('abc'), n2['g']('abc')) for _ in range(4)])
g1 = n1['g']
g3 = types.FunctionType(g1.__code__, {'len': lambda v: 'three'})
print([(g1('ab'), g3('ab')) for _ in range(4)])

# Defining the global after the site went to builtins, and deleting it again.
def h(v):
    return len(v)
r = [h('xy') for _ in range(4)]
len = lambda v: 'mine'
r += [h('xy') for _ in range(4)]
del len
r += [h('xy') for _ in range(4)]
print(r)

# More names than the cache's index holds.
g = {}
for i in range(70000):
    g['n%d' % i] = i
exec('def last():\n    return n69999\ndef first():\n    return n0\n', g)
print([g['last']() for _ in range(4)], [g['first']() for _ in range(4)])

# Rebinding and deleting a cached global.
x = 1
def rd():
    return x
out = [rd() for _ in range(3)]
x = 2
out += [rd() for _ in range(3)]
del x
try:
    rd()
except NameError as e:
    out.append(str(e))
x = 3
out += [rd() for _ in range(3)]
print(out)

# A dict subclass as globals.
class NS(dict):
    pass
s1 = NS(); exec(code, s1); s1['x'] = 's1'
s2 = NS(); s2['pad'] = 0; s2['x'] = 's2'; exec(code, s2)
print([(s1['f'](), s2['f']()) for _ in range(4)])
