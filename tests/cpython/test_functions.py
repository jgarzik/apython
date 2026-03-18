"""Tests for function features — defaults, varargs, kwargs, closures, recursion"""

import unittest


class FunctionBasicTest(unittest.TestCase):

    def test_no_args(self):
        def f():
            return 42
        self.assertEqual(f(), 42)

    def test_positional(self):
        def f(a, b, c):
            return a + b + c
        self.assertEqual(f(1, 2, 3), 6)

    def test_default_args(self):
        def f(a, b=10, c=20):
            return a + b + c
        self.assertEqual(f(1), 31)
        self.assertEqual(f(1, 2), 23)
        self.assertEqual(f(1, 2, 3), 6)

    def test_keyword_args(self):
        def f(a, b=0, c=0):
            return (a, b, c)
        self.assertEqual(f(1, c=3), (1, 0, 3))
        self.assertEqual(f(1, b=2, c=3), (1, 2, 3))

    def test_keyword_only(self):
        def f(a, *, b, c=10):
            return a + b + c
        self.assertEqual(f(1, b=2), 13)
        self.assertEqual(f(1, b=2, c=3), 6)

    def test_varargs(self):
        def f(*args):
            return args
        self.assertEqual(f(), ())
        self.assertEqual(f(1, 2, 3), (1, 2, 3))

    def test_kwargs(self):
        def f(**kw):
            return sorted(kw.items())
        self.assertEqual(f(a=1, b=2), [('a', 1), ('b', 2)])

    def test_mixed(self):
        def f(a, b, *args, **kw):
            return (a, b, args, sorted(kw.items()))
        result = f(1, 2, 3, 4, x=5)
        self.assertEqual(result, (1, 2, (3, 4), [('x', 5)]))

    def test_return_none(self):
        def f():
            pass
        self.assertIsNone(f())

    def test_multiple_return(self):
        def f():
            return 1, 2, 3
        a, b, c = f()
        self.assertEqual((a, b, c), (1, 2, 3))


class RecursionTest(unittest.TestCase):

    def test_factorial(self):
        def fact(n):
            if n <= 1:
                return 1
            return n * fact(n - 1)
        self.assertEqual(fact(10), 3628800)

    def test_fibonacci(self):
        def fib(n):
            if n < 2:
                return n
            return fib(n - 1) + fib(n - 2)
        self.assertEqual(fib(10), 55)

    def test_mutual_recursion(self):
        def is_even(n):
            if n == 0:
                return True
            return is_odd(n - 1)
        def is_odd(n):
            if n == 0:
                return False
            return is_even(n - 1)
        self.assertTrue(is_even(10))
        self.assertFalse(is_even(11))
        self.assertTrue(is_odd(7))


class HigherOrderTest(unittest.TestCase):

    def test_function_as_arg(self):
        def apply(f, x):
            return f(x)
        self.assertEqual(apply(str, 42), "42")
        self.assertEqual(apply(len, [1, 2, 3]), 3)

    def test_function_as_return(self):
        def make_adder(n):
            def adder(x):
                return x + n
            return adder
        add10 = make_adder(10)
        self.assertEqual(add10(5), 15)

    def test_map(self):
        result = list(map(lambda x: x * 2, [1, 2, 3]))
        self.assertEqual(result, [2, 4, 6])

    def test_filter(self):
        result = list(filter(lambda x: x > 2, [1, 2, 3, 4, 5]))
        self.assertEqual(result, [3, 4, 5])

    def test_sorted_key(self):
        data = ["banana", "apple", "cherry"]
        result = sorted(data, key=len)
        self.assertEqual(result, ["apple", "banana", "cherry"])


if __name__ == "__main__":
    unittest.main()
