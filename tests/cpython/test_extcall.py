"""Tests for extended function call syntax — adapted from CPython test_extcall.py"""

import unittest


class ExtCallTest(unittest.TestCase):

    def test_basic_star_args(self):
        def f(*args):
            return args
        self.assertEqual(f(*(1, 2, 3)), (1, 2, 3))
        self.assertEqual(f(*[1, 2, 3]), (1, 2, 3))

    def test_basic_kwargs(self):
        def f(**kwargs):
            return kwargs
        self.assertEqual(f(**{'a': 1, 'b': 2}), {'a': 1, 'b': 2})
        self.assertEqual(f(), {})

    def test_mixed_args_kwargs(self):
        def f(*args, **kwargs):
            return args, kwargs
        self.assertEqual(f(1, 2, a=3), ((1, 2), {'a': 3}))
        self.assertEqual(f(*(1, 2), **{'a': 3}), ((1, 2), {'a': 3}))

    def test_positional_and_star(self):
        def f(a, b, c):
            return a + b + c
        self.assertEqual(f(1, *(2, 3)), 6)
        self.assertEqual(f(*(1, 2, 3)), 6)

    def test_keyword_args(self):
        def f(a, b=10, c=20):
            return (a, b, c)
        self.assertEqual(f(1), (1, 10, 20))
        self.assertEqual(f(1, b=2), (1, 2, 20))
        self.assertEqual(f(1, c=3), (1, 10, 3))
        self.assertEqual(f(1, b=2, c=3), (1, 2, 3))

    def test_keyword_only_args(self):
        def f(a, *, b, c=10):
            return (a, b, c)
        self.assertEqual(f(1, b=2), (1, 2, 10))
        self.assertEqual(f(1, b=2, c=3), (1, 2, 3))

    def test_star_in_call(self):
        def f(a, b, c, d):
            return a * 1000 + b * 100 + c * 10 + d
        self.assertEqual(f(1, *(2, 3), **{'d': 4}), 1234)

    def test_double_star_dict(self):
        def f(**kw):
            return sorted(kw.items())
        d = {'a': 1, 'b': 2}
        self.assertEqual(f(**d), [('a', 1), ('b', 2)])

    def test_default_args(self):
        def f(a, b=2, c=3):
            return (a, b, c)
        self.assertEqual(f(1), (1, 2, 3))
        self.assertEqual(f(1, 5), (1, 5, 3))
        self.assertEqual(f(1, 5, 7), (1, 5, 7))

    def test_varargs_and_defaults(self):
        def f(a, b=10, *args):
            return (a, b, args)
        self.assertEqual(f(1), (1, 10, ()))
        self.assertEqual(f(1, 2), (1, 2, ()))
        self.assertEqual(f(1, 2, 3, 4), (1, 2, (3, 4)))

    def test_too_few_args(self):
        def f(a, b):
            pass
        self.assertRaises(TypeError, f)
        self.assertRaises(TypeError, f, 1)

    def test_too_many_args(self):
        def f(a):
            pass
        self.assertRaises(TypeError, f, 1, 2)


if __name__ == "__main__":
    unittest.main()
