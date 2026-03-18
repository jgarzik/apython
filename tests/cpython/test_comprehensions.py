"""Comprehensive tests for all comprehension forms"""

import unittest


class ListCompTest(unittest.TestCase):

    def test_basic(self):
        self.assertEqual([x for x in range(5)], [0, 1, 2, 3, 4])

    def test_with_filter(self):
        self.assertEqual([x for x in range(10) if x % 2 == 0], [0, 2, 4, 6, 8])

    def test_with_expression(self):
        self.assertEqual([x * x for x in range(5)], [0, 1, 4, 9, 16])

    def test_nested(self):
        self.assertEqual([(i, j) for i in range(2) for j in range(3)],
                         [(0,0), (0,1), (0,2), (1,0), (1,1), (1,2)])

    def test_nested_with_filter(self):
        self.assertEqual([(i, j) for i in range(3) for j in range(3) if i != j],
                         [(0,1), (0,2), (1,0), (1,2), (2,0), (2,1)])

    def test_string_input(self):
        self.assertEqual([c.upper() for c in "abc"], ['A', 'B', 'C'])

    def test_nested_comp(self):
        self.assertEqual([[j for j in range(i)] for i in range(4)],
                         [[], [0], [0, 1], [0, 1, 2]])

    def test_closure(self):
        n = 10
        self.assertEqual([x + n for x in range(3)], [10, 11, 12])

    def test_empty(self):
        self.assertEqual([x for x in []], [])
        self.assertEqual([x for x in range(10) if x > 100], [])


class DictCompTest(unittest.TestCase):

    def test_basic(self):
        d = {k: v for k, v in [('a', 1), ('b', 2)]}
        self.assertEqual(d['a'], 1)
        self.assertEqual(d['b'], 2)

    def test_from_range(self):
        d = {x: x * x for x in range(4)}
        self.assertEqual(len(d), 4)
        self.assertEqual(d[3], 9)

    def test_with_filter(self):
        d = {x: x for x in range(10) if x % 2 == 0}
        self.assertEqual(sorted(d.keys()), [0, 2, 4, 6, 8])

    def test_swap_keys_values(self):
        original = {'a': 1, 'b': 2, 'c': 3}
        swapped = {v: k for k, v in original.items()}
        self.assertEqual(swapped[1], 'a')
        self.assertEqual(swapped[2], 'b')


class SetCompTest(unittest.TestCase):

    def test_basic(self):
        s = {x for x in range(5)}
        self.assertEqual(len(s), 5)

    def test_with_filter(self):
        s = {x for x in range(10) if x % 3 == 0}
        self.assertEqual(sorted(list(s)), [0, 3, 6, 9])

    def test_dedup(self):
        s = {x % 3 for x in range(10)}
        self.assertEqual(len(s), 3)


class GenExpTest(unittest.TestCase):

    def test_sum(self):
        self.assertEqual(sum(x for x in range(5)), 10)

    def test_any_all(self):
        self.assertTrue(any(x > 3 for x in range(5)))
        self.assertFalse(any(x > 10 for x in range(5)))
        self.assertTrue(all(x < 5 for x in range(5)))

    def test_list_from_gen(self):
        self.assertEqual(list(x * 2 for x in range(4)), [0, 2, 4, 6])

    def test_nested_gen(self):
        self.assertEqual(list((i, j) for i in range(2) for j in range(2)),
                         [(0,0), (0,1), (1,0), (1,1)])

    def test_filter(self):
        self.assertEqual(list(x for x in range(10) if x % 3 == 0),
                         [0, 3, 6, 9])

    def test_max_min(self):
        self.assertEqual(max(x * x for x in range(5)), 16)
        self.assertEqual(min(x * x for x in range(1, 5)), 1)


if __name__ == "__main__":
    unittest.main()
