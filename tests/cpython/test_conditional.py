"""Tests for conditional expressions and boolean logic"""

import unittest


class TernaryTest(unittest.TestCase):

    def test_true(self):
        self.assertEqual("yes" if True else "no", "yes")

    def test_false(self):
        self.assertEqual("yes" if False else "no", "no")

    def test_expression(self):
        x = 10
        self.assertEqual("big" if x > 5 else "small", "big")
        self.assertEqual("big" if x < 5 else "small", "small")

    def test_nested(self):
        def classify(x):
            return "pos" if x > 0 else "zero" if x == 0 else "neg"
        self.assertEqual(classify(5), "pos")
        self.assertEqual(classify(0), "zero")
        self.assertEqual(classify(-5), "neg")

    def test_in_list(self):
        result = [x if x > 0 else 0 for x in [-2, -1, 0, 1, 2]]
        self.assertEqual(result, [0, 0, 0, 1, 2])


class BooleanLogicTest(unittest.TestCase):

    def test_and_short_circuit(self):
        self.assertEqual(0 and 42, 0)
        self.assertEqual(1 and 42, 42)
        self.assertEqual("" and "hello", "")
        self.assertEqual("x" and "hello", "hello")

    def test_or_short_circuit(self):
        self.assertEqual(0 or 42, 42)
        self.assertEqual(1 or 42, 1)
        self.assertEqual("" or "hello", "hello")
        self.assertEqual("x" or "hello", "x")

    def test_not(self):
        self.assertEqual(not True, False)
        self.assertEqual(not False, True)
        self.assertEqual(not 0, True)
        self.assertEqual(not 1, False)
        self.assertEqual(not "", True)
        self.assertEqual(not "x", False)
        self.assertEqual(not None, True)

    def test_chained_and_or(self):
        self.assertEqual(1 and 2 and 3, 3)
        self.assertEqual(1 and 0 and 3, 0)
        self.assertEqual(0 or 0 or 3, 3)
        self.assertEqual(0 or 2 or 3, 2)

    def test_complex_boolean(self):
        x, y = 5, 10
        self.assertTrue(x > 0 and y > 0)
        self.assertFalse(x > 0 and y < 0)
        self.assertTrue(x > 0 or y < 0)
        self.assertFalse(x < 0 or y < 0)

    def test_default_pattern(self):
        def f(x=None):
            return x or "default"
        self.assertEqual(f(), "default")
        self.assertEqual(f("value"), "value")
        self.assertEqual(f(0), "default")  # 0 is falsy


class IdentityTest(unittest.TestCase):

    def test_is(self):
        a = [1, 2]
        b = a
        c = [1, 2]
        self.assertTrue(a is b)
        self.assertFalse(a is c)

    def test_is_not(self):
        a = [1, 2]
        c = [1, 2]
        self.assertTrue(a is not c)
        self.assertFalse(a is not a)

    def test_none_identity(self):
        self.assertTrue(None is None)
        self.assertFalse(None is not None)
        self.assertFalse(0 is None)

    def test_bool_identity(self):
        self.assertTrue(True is True)
        self.assertTrue(False is False)
        self.assertFalse(True is False)


if __name__ == "__main__":
    unittest.main()
