"""Generator expression tests — adapted from CPython test_genexps.py"""

import unittest


class GenExpTestCase(unittest.TestCase):

    def test_simple(self):
        self.assertEqual(list(x for x in range(10)), list(range(10)))

    def test_conditional(self):
        self.assertEqual(list(x for x in range(10) if x % 2 == 0),
                         [0, 2, 4, 6, 8])

    def test_sum(self):
        self.assertEqual(sum(x**2 for x in range(10)),
                         sum([x**2 for x in range(10)]))

    def test_nested(self):
        self.assertEqual(list((x, y) for x in range(3) for y in range(4)),
                         [(x, y) for x in range(3) for y in range(4)])

    def test_nested_conditional(self):
        self.assertEqual(
            list((x, y) for x in range(4) for y in range(4) if x != y),
            [(x, y) for x in range(4) for y in range(4) if x != y])

    def test_in_function_call(self):
        self.assertEqual(list(x for x in range(5)), [0, 1, 2, 3, 4])
        self.assertEqual(tuple(x for x in range(5)), (0, 1, 2, 3, 4))

    def test_multiple_use(self):
        # Generator can only be iterated once
        g = (x for x in range(5))
        self.assertEqual(list(g), [0, 1, 2, 3, 4])
        self.assertEqual(list(g), [])

    def test_next(self):
        g = (x for x in range(3))
        self.assertEqual(next(g), 0)
        self.assertEqual(next(g), 1)
        self.assertEqual(next(g), 2)
        self.assertRaises(StopIteration, next, g)

    def test_early_termination(self):
        # Taking only some elements
        g = (x for x in range(100))
        first_five = [next(g) for _ in range(5)]
        self.assertEqual(first_five, [0, 1, 2, 3, 4])

    def test_expression_types(self):
        # Various expression results
        self.assertEqual(list(x*x for x in range(5)), [0, 1, 4, 9, 16])
        self.assertEqual(list(str(x) for x in range(3)), ['0', '1', '2'])

    def test_scope(self):
        # Generator expression doesn't leak iteration variable
        x = 42
        g = list(x for x in range(5))
        self.assertEqual(x, 42)

    def test_closure(self):
        def make_gen(n):
            return (x + n for x in range(5))
        self.assertEqual(list(make_gen(10)), [10, 11, 12, 13, 14])

    def test_bool(self):
        self.assertTrue(any(x > 3 for x in range(10)))
        self.assertFalse(any(x > 10 for x in range(10)))
        self.assertTrue(all(x < 10 for x in range(10)))
        self.assertFalse(all(x < 5 for x in range(10)))

    def test_empty(self):
        self.assertEqual(list(x for x in []), [])
        self.assertEqual(list(x for x in range(0)), [])


if __name__ == "__main__":
    unittest.main()
