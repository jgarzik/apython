"""Tests for match statement (PEP 634)"""

import unittest


class MatchBasicTest(unittest.TestCase):

    def test_literal(self):
        def f(x):
            match x:
                case 1:
                    return "one"
                case 2:
                    return "two"
                case _:
                    return "other"
        self.assertEqual(f(1), "one")
        self.assertEqual(f(2), "two")
        self.assertEqual(f(99), "other")

    def test_string_literal(self):
        def f(cmd):
            match cmd:
                case "start":
                    return 1
                case "stop":
                    return 0
                case _:
                    return -1
        self.assertEqual(f("start"), 1)
        self.assertEqual(f("stop"), 0)
        self.assertEqual(f("other"), -1)

    def test_capture(self):
        def f(x):
            match x:
                case [a, b]:
                    return a + b
                case _:
                    return -1
        self.assertEqual(f([10, 20]), 30)

    def test_or_pattern(self):
        def f(x):
            match x:
                case 1 | 2 | 3:
                    return "small"
                case _:
                    return "big"
        self.assertEqual(f(1), "small")
        self.assertEqual(f(2), "small")
        self.assertEqual(f(5), "big")

    def test_guard(self):
        def f(x):
            match x:
                case n if n > 0:
                    return "positive"
                case n if n < 0:
                    return "negative"
                case _:
                    return "zero"
        self.assertEqual(f(5), "positive")
        self.assertEqual(f(-3), "negative")
        self.assertEqual(f(0), "zero")

    def test_tuple_pattern(self):
        def f(point):
            match point:
                case (0, 0):
                    return "origin"
                case (x, 0):
                    return "x-axis"
                case (0, y):
                    return "y-axis"
                case (x, y):
                    return "other"
        self.assertEqual(f((0, 0)), "origin")
        self.assertEqual(f((5, 0)), "x-axis")
        self.assertEqual(f((0, 3)), "y-axis")
        self.assertEqual(f((1, 2)), "other")

    def test_none_pattern(self):
        def f(x):
            match x:
                case None:
                    return "none"
                case _:
                    return "something"
        self.assertEqual(f(None), "none")
        self.assertEqual(f(42), "something")

    def test_bool_pattern(self):
        def f(x):
            match x:
                case True:
                    return "true"
                case False:
                    return "false"
                case _:
                    return "other"
        self.assertEqual(f(True), "true")
        self.assertEqual(f(False), "false")


if __name__ == "__main__":
    unittest.main()
