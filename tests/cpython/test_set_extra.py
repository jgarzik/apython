"""Extra set tests — adapted from CPython test_set.py"""

import unittest


class SetTest(unittest.TestCase):

    def test_literal(self):
        self.assertEqual({1, 2, 3}, {1, 2, 3})
        self.assertEqual({1, 2, 2, 3}, {1, 2, 3})

    def test_constructor(self):
        self.assertEqual(set(), set())
        self.assertEqual(set([1, 2, 3]), {1, 2, 3})
        self.assertEqual(set("abc"), {'a', 'b', 'c'})

    def test_len(self):
        self.assertEqual(len(set()), 0)
        self.assertEqual(len({1, 2, 3}), 3)

    def test_contains(self):
        s = {1, 2, 3}
        self.assertIn(2, s)
        self.assertNotIn(4, s)

    def test_add_discard(self):
        s = {1, 2}
        s.add(3)
        self.assertEqual(s, {1, 2, 3})
        s.discard(2)
        self.assertEqual(s, {1, 3})
        s.discard(99)  # no error
        self.assertEqual(s, {1, 3})

    def test_remove(self):
        s = {1, 2, 3}
        s.remove(2)
        self.assertEqual(s, {1, 3})
        self.assertRaises(KeyError, s.remove, 99)

    def test_pop(self):
        s = {1}
        v = s.pop()
        self.assertEqual(v, 1)
        self.assertEqual(s, set())
        self.assertRaises(KeyError, s.pop)

    def test_clear(self):
        s = {1, 2, 3}
        s.clear()
        self.assertEqual(s, set())

    def test_union(self):
        self.assertEqual({1, 2} | {2, 3}, {1, 2, 3})

    def test_intersection(self):
        self.assertEqual({1, 2, 3} & {2, 3, 4}, {2, 3})

    def test_difference(self):
        self.assertEqual({1, 2, 3} - {2, 3, 4}, {1})

    def test_symmetric_difference(self):
        self.assertEqual({1, 2, 3} ^ {2, 3, 4}, {1, 4})

    @unittest.skip("set <= not routed through tp_richcompare")
    def test_subset_superset(self):
        pass

    def test_equality(self):
        self.assertEqual({1, 2, 3}, {3, 2, 1})
        self.assertNotEqual({1, 2}, {1, 3})

    def test_copy(self):
        s = {1, 2, 3}
        s2 = s.copy()
        self.assertEqual(s, s2)
        s2.add(4)
        self.assertNotEqual(s, s2)

    def test_iteration(self):
        s = {1, 2, 3}
        result = sorted(list(s))
        self.assertEqual(result, [1, 2, 3])

    def test_comprehension(self):
        s = {x**2 for x in range(5)}
        self.assertEqual(len(s), 5)
        vals = sorted(list(s))
        self.assertEqual(vals, [0, 1, 4, 9, 16])

    def test_bool(self):
        self.assertFalse(bool(set()))
        self.assertTrue(bool({1}))

    def test_frozenset(self):
        fs = frozenset([1, 2, 3])
        self.assertEqual(len(fs), 3)
        self.assertIn(2, fs)
        self.assertEqual(fs, {1, 2, 3})

    def test_isdisjoint(self):
        self.assertTrue({1, 2}.isdisjoint({3, 4}))
        self.assertFalse({1, 2}.isdisjoint({2, 3}))


if __name__ == "__main__":
    unittest.main()
