"""Tests for global and nonlocal statements"""

import unittest


class GlobalTest(unittest.TestCase):

    def test_global_read(self):
        x = 42
        def f():
            return x
        self.assertEqual(f(), 42)

    def test_global_write(self):
        def f():
            global _test_global_var
            _test_global_var = 99
        f()
        self.assertEqual(_test_global_var, 99)

    def test_global_in_nested(self):
        result = []
        def outer():
            def inner():
                global _test_nested_global
                _test_nested_global = 42
            inner()
        outer()
        self.assertEqual(_test_nested_global, 42)


class NonlocalTest(unittest.TestCase):

    def test_nonlocal_read(self):
        def outer():
            x = 10
            def inner():
                return x
            return inner()
        self.assertEqual(outer(), 10)

    def test_nonlocal_write(self):
        def outer():
            x = 10
            def inner():
                nonlocal x
                x = 20
            inner()
            return x
        self.assertEqual(outer(), 20)

    def test_nonlocal_counter(self):
        def make_counter():
            count = 0
            def increment():
                nonlocal count
                count += 1
                return count
            return increment
        c = make_counter()
        self.assertEqual(c(), 1)
        self.assertEqual(c(), 2)
        self.assertEqual(c(), 3)

    def test_nonlocal_multi_level(self):
        def outer():
            x = 0
            def middle():
                nonlocal x
                x += 1
                def inner():
                    nonlocal x
                    x += 10
                inner()
            middle()
            return x
        self.assertEqual(outer(), 11)

    def test_nonlocal_multiple_vars(self):
        def outer():
            a = 1
            b = 2
            def inner():
                nonlocal a, b
                a, b = b, a
            inner()
            return a, b
        self.assertEqual(outer(), (2, 1))


class ScopeTest(unittest.TestCase):

    def test_local_shadows_global(self):
        x = 100
        def f():
            x = 200
            return x
        self.assertEqual(f(), 200)
        self.assertEqual(x, 100)

    def test_enclosing_scope(self):
        def outer(x):
            def inner(y):
                return x + y
            return inner
        add5 = outer(5)
        self.assertEqual(add5(3), 8)

    def test_class_scope(self):
        class C:
            x = 42
            def get_x(self):
                return self.x
        self.assertEqual(C().get_x(), 42)

    def test_comprehension_scope(self):
        x = 99
        _ = [x for x in range(5)]
        self.assertEqual(x, 99)  # comprehension doesn't leak


if __name__ == "__main__":
    unittest.main()
