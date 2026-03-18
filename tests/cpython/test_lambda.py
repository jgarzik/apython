"""Tests for lambda expressions — adapted from CPython tests"""

import unittest


class LambdaTest(unittest.TestCase):

    def test_basic(self):
        f = lambda: 42
        self.assertEqual(f(), 42)

    def test_args(self):
        f = lambda x, y: x + y
        self.assertEqual(f(1, 2), 3)

    def test_default_args(self):
        f = lambda x, y=10: x + y
        self.assertEqual(f(1), 11)
        self.assertEqual(f(1, 2), 3)

    def test_varargs(self):
        f = lambda *args: sum(args)
        self.assertEqual(f(1, 2, 3), 6)

    def test_kwargs(self):
        f = lambda **kw: sorted(kw.items())
        self.assertEqual(f(a=1, b=2), [('a', 1), ('b', 2)])

    def test_closure(self):
        def make_adder(n):
            return lambda x: x + n
        add5 = make_adder(5)
        self.assertEqual(add5(3), 8)
        self.assertEqual(add5(10), 15)

    def test_nested_lambda(self):
        f = lambda x: (lambda y: x + y)
        self.assertEqual(f(10)(20), 30)

    def test_in_list(self):
        funcs = [lambda x, i=i: x + i for i in range(5)]
        results = [f(10) for f in funcs]
        self.assertEqual(results, [10, 11, 12, 13, 14])

    def test_conditional(self):
        f = lambda x: "pos" if x > 0 else "non-pos"
        self.assertEqual(f(1), "pos")
        self.assertEqual(f(0), "non-pos")
        self.assertEqual(f(-1), "non-pos")

    def test_as_callback(self):
        data = [3, 1, 4, 1, 5, 9]
        self.assertEqual(sorted(data, key=lambda x: -x),
                         [9, 5, 4, 3, 1, 1])

    def test_immediately_invoked(self):
        result = (lambda x, y: x * y)(6, 7)
        self.assertEqual(result, 42)

    def test_map_filter(self):
        self.assertEqual(list(map(lambda x: x**2, range(5))),
                         [0, 1, 4, 9, 16])
        self.assertEqual(list(filter(lambda x: x % 2, range(8))),
                         [1, 3, 5, 7])


if __name__ == "__main__":
    unittest.main()
