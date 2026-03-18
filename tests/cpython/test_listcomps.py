"""List comprehension tests — adapted from CPython test_listcomps.py"""

import unittest


class ListComprehensionTest(unittest.TestCase):

    def test_simple(self):
        self.assertEqual([x for x in range(10)], list(range(10)))

    def test_conditional(self):
        self.assertEqual([x for x in range(10) if x % 2 == 0],
                         [0, 2, 4, 6, 8])

    def test_nested(self):
        self.assertEqual([(x, y) for x in range(3) for y in range(4)],
                         [(i, j) for i in range(3) for j in range(4)])

    def test_nested_conditional(self):
        self.assertEqual(
            [(x, y) for x in range(4) for y in range(4) if x != y],
            [(i, j) for i in range(4) for j in range(4) if i != j])

    def test_expressions(self):
        self.assertEqual([x*x for x in range(6)], [0, 1, 4, 9, 16, 25])
        self.assertEqual([str(x) for x in range(4)], ['0', '1', '2', '3'])
        self.assertEqual([x + 1 for x in range(5)], [1, 2, 3, 4, 5])

    def test_scope(self):
        # List comprehension variable doesn't leak
        x = 42
        y = [x for x in range(5)]
        self.assertEqual(x, 42)
        self.assertEqual(y, [0, 1, 2, 3, 4])

    def test_empty_iterable(self):
        self.assertEqual([x for x in []], [])
        self.assertEqual([x for x in range(0)], [])

    def test_with_function_calls(self):
        self.assertEqual([len(s) for s in ['a', 'bb', 'ccc']], [1, 2, 3])

    def test_nested_listcomp(self):
        self.assertEqual([[j for j in range(i)] for i in range(4)],
                         [[], [0], [0, 1], [0, 1, 2]])

    def test_closure(self):
        def make_list(n):
            return [x + n for x in range(5)]
        self.assertEqual(make_list(10), [10, 11, 12, 13, 14])

    def test_multiple_for(self):
        result = [x * y for x in range(1, 4) for y in range(1, 4)]
        self.assertEqual(result, [1, 2, 3, 2, 4, 6, 3, 6, 9])

    def test_string_iteration(self):
        self.assertEqual([c for c in 'abc'], ['a', 'b', 'c'])

    def test_tuple_result(self):
        self.assertEqual([(x, x*x) for x in range(4)],
                         [(0, 0), (1, 1), (2, 4), (3, 9)])

    def test_dict_comp_basic(self):
        self.assertEqual({x: x*x for x in range(5)},
                         {0: 0, 1: 1, 2: 4, 3: 9, 4: 16})

    def test_set_comp_basic(self):
        self.assertEqual({x % 3 for x in range(10)}, {0, 1, 2})


if __name__ == "__main__":
    unittest.main()
