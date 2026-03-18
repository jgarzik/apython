"""Extra decorator tests"""

import unittest


class DecoratorTest(unittest.TestCase):

    def test_function_decorator(self):
        def double(f):
            def wrapper(*args):
                return f(*args) * 2
            return wrapper
        @double
        def add(a, b):
            return a + b
        self.assertEqual(add(3, 4), 14)

    def test_stacked_decorators(self):
        def add_one(f):
            def w(*a):
                return f(*a) + 1
            return w
        def times_two(f):
            def w(*a):
                return f(*a) * 2
            return w
        @add_one
        @times_two
        def val():
            return 5
        # times_two applied first: 5*2=10, then add_one: 10+1=11
        self.assertEqual(val(), 11)

    def test_decorator_with_args(self):
        def repeat(n):
            def decorator(f):
                def wrapper(*args):
                    return [f(*args) for _ in range(n)]
                return wrapper
            return decorator
        @repeat(3)
        def greet():
            return "hi"
        self.assertEqual(greet(), ["hi", "hi", "hi"])

    def test_class_decorator(self):
        def add_method(cls):
            cls.extra = lambda self: 42
            return cls
        @add_method
        class C:
            pass
        self.assertEqual(C().extra(), 42)

    def test_method_decorator(self):
        def log(f):
            def wrapper(self, *args):
                self.calls.append(f.__name__)
                return f(self, *args)
            return wrapper
        class C:
            def __init__(self):
                self.calls = []
            @log
            def do_thing(self):
                return "done"
        obj = C()
        obj.do_thing()
        self.assertEqual(obj.calls, ["do_thing"])

    def test_staticmethod(self):
        class C:
            @staticmethod
            def f(x):
                return x + 1
        self.assertEqual(C.f(5), 6)
        self.assertEqual(C().f(5), 6)

    def test_classmethod(self):
        class C:
            val = 10
            @classmethod
            def get_val(cls):
                return cls.val
        self.assertEqual(C.get_val(), 10)

    def test_property_decorator(self):
        class C:
            def __init__(self, x):
                self._x = x
            @property
            def x(self):
                return self._x
            @x.setter
            def x(self, val):
                self._x = val
        obj = C(10)
        self.assertEqual(obj.x, 10)
        obj.x = 20
        self.assertEqual(obj.x, 20)


if __name__ == "__main__":
    unittest.main()
