"""Tests for closures and nonlocal — adapted from CPython tests"""

import unittest


class ClosureTest(unittest.TestCase):

    def test_basic_closure(self):
        def outer(x):
            def inner():
                return x
            return inner
        self.assertEqual(outer(42)(), 42)

    def test_closure_mutation(self):
        def counter():
            n = 0
            def inc():
                nonlocal n
                n += 1
                return n
            return inc
        c = counter()
        self.assertEqual(c(), 1)
        self.assertEqual(c(), 2)
        self.assertEqual(c(), 3)

    def test_multiple_closures(self):
        def make_pair(x):
            def get():
                return x
            def set_(val):
                nonlocal x
                x = val
            return get, set_
        g, s = make_pair(10)
        self.assertEqual(g(), 10)
        s(20)
        self.assertEqual(g(), 20)

    def test_nested_closures(self):
        def outer(x):
            def middle(y):
                def inner():
                    return x + y
                return inner
            return middle
        self.assertEqual(outer(10)(20)(), 30)

    def test_closure_in_loop(self):
        funcs = []
        for i in range(5):
            def f(n=i):
                return n
            funcs.append(f)
        self.assertEqual([f() for f in funcs], [0, 1, 2, 3, 4])

    def test_shared_closure(self):
        def make_adders():
            fns = []
            for i in range(3):
                def adder(x, i=i):
                    return x + i
                fns.append(adder)
            return fns
        adders = make_adders()
        self.assertEqual(adders[0](10), 10)
        self.assertEqual(adders[1](10), 11)
        self.assertEqual(adders[2](10), 12)

    def test_closure_over_param(self):
        def factory(greeting):
            def greet(name):
                return greeting + " " + name
            return greet
        hello = factory("hello")
        self.assertEqual(hello("world"), "hello world")

    def test_nonlocal_in_nested(self):
        result = []
        def outer():
            x = 0
            def inner():
                nonlocal x
                x += 1
                result.append(x)
            inner()
            inner()
            inner()
        outer()
        self.assertEqual(result, [1, 2, 3])

    def test_closure_with_defaults(self):
        def make_pow(exp):
            def power(base):
                return base ** exp
            return power
        square = make_pow(2)
        cube = make_pow(3)
        self.assertEqual(square(5), 25)
        self.assertEqual(cube(3), 27)

    def test_lambda_closure(self):
        def make_adder(n):
            return lambda x: x + n
        add10 = make_adder(10)
        self.assertEqual(add10(5), 15)

    def test_closure_survives_outer(self):
        def make():
            data = [1, 2, 3]
            def get():
                return data
            return get
        g = make()
        self.assertEqual(g(), [1, 2, 3])
        self.assertEqual(g(), [1, 2, 3])


if __name__ == "__main__":
    unittest.main()
