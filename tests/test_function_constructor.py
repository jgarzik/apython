# types.FunctionType(code, globals, name=None, argdefs=None, closure=None)
# builds a function from a code object -- the way code is
# copied with new globals or a new closure.  It was "cannot create 'function'
# instances".  A closure must match the code's free variables one for one.
import types


def outer():
    y = 10

    def f(a, b=2):
        return a + b + y
    return f


f = outer()
g = types.FunctionType(f.__code__, {"__builtins__": __builtins__}, "g", (5,),
                       f.__closure__)
print(g(1), g.__name__, g.__defaults__, g.__kwdefaults__, g.__closure__ is f.__closure__)

k = types.FunctionType(compile("def k(): return 7", "m", "exec").co_consts[0], globals())
print(k(), k.__name__, k.__defaults__, k.__closure__)
print(types.FunctionType(k.__code__, globals(), name="kw").__name__)
print(types.FunctionType(code=k.__code__, globals=globals(), argdefs=None)())

cell = types.CellType(1000)
h = types.FunctionType(f.__code__, globals(), None, None, (cell,))
print(h(1, 2))

for bad in [(1, {}), (k.__code__, 1), (f.__code__, {}), (k.__code__, {}, 5),
            (k.__code__, {}, None, [1]), (f.__code__, {}, None, None, ()),
            (k.__code__, {}, None, None, None, {})]:
    try:
        types.FunctionType(*bad)
        print("accepted", bad)
    except (TypeError, ValueError) as e:
        print(type(e).__name__)
