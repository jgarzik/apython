"""CPython test_set.py adapted for apython."""
import unittest

class TestSet(unittest.TestCase):

    def test_uniquification(self):
        s = set([1, 1, 2, 2, 3, 3])
        self.assertEqual(sorted(s), [1, 2, 3])

    def test_len(self):
        self.assertEqual(len(set()), 0)
        self.assertEqual(len(set([1, 2, 3])), 3)
        self.assertEqual(len({1, 2, 3}), 3)

    def test_contains(self):
        s = {1, 2, 3}
        self.assertIn(1, s)
        self.assertIn(2, s)
        self.assertIn(3, s)
        self.assertNotIn(4, s)
        self.assertNotIn('a', s)

    def test_union(self):
        a = {1, 2, 3}
        b = {2, 3, 4}
        self.assertEqual(sorted(a | b), [1, 2, 3, 4])
        self.assertEqual(sorted(a.union(b)), [1, 2, 3, 4])
        # Union with empty
        self.assertEqual(a | set(), a)
        self.assertEqual(set() | a, a)

    def test_intersection(self):
        a = {1, 2, 3}
        b = {2, 3, 4}
        self.assertEqual(sorted(a & b), [2, 3])
        self.assertEqual(sorted(a.intersection(b)), [2, 3])
        # Intersection with empty
        self.assertEqual(a & set(), set())

    def test_difference(self):
        a = {1, 2, 3}
        b = {2, 3, 4}
        self.assertEqual(sorted(a - b), [1])
        self.assertEqual(sorted(a.difference(b)), [1])

    def test_symmetric_difference(self):
        a = {1, 2, 3}
        b = {2, 3, 4}
        self.assertEqual(sorted(a ^ b), [1, 4])
        self.assertEqual(sorted(a.symmetric_difference(b)), [1, 4])

    def test_isdisjoint(self):
        self.assertTrue({1, 2}.isdisjoint({3, 4}))
        self.assertFalse({1, 2}.isdisjoint({2, 3}))
        self.assertTrue(set().isdisjoint(set()))

    def test_issubset(self):
        self.assertTrue({1, 2}.issubset({1, 2, 3}))
        self.assertTrue(set().issubset({1}))
        self.assertFalse({1, 2, 3}.issubset({1, 2}))
        self.assertTrue({1, 2}.issubset({1, 2}))

    def test_issuperset(self):
        self.assertTrue({1, 2, 3}.issuperset({1, 2}))
        self.assertTrue({1}.issuperset(set()))
        self.assertFalse({1, 2}.issuperset({1, 2, 3}))
        self.assertTrue({1, 2}.issuperset({1, 2}))

    def test_equality(self):
        self.assertEqual(set(), set())
        self.assertEqual({1, 2, 3}, {1, 2, 3})
        self.assertEqual({1, 2, 3}, {3, 2, 1})
        self.assertNotEqual({1, 2}, {1, 2, 3})
        self.assertNotEqual({1, 2, 3}, {1, 2})

    def test_clear(self):
        s = {1, 2, 3}
        s.clear()
        self.assertEqual(len(s), 0)
        self.assertEqual(s, set())

    def test_copy(self):
        s = {1, 2, 3}
        t = s.copy()
        self.assertEqual(s, t)
        self.assertIsNot(s, t)

    def test_add(self):
        s = set()
        s.add(1)
        s.add(2)
        s.add(2)  # duplicate
        self.assertEqual(sorted(s), [1, 2])

    def test_remove(self):
        s = {1, 2, 3}
        s.remove(2)
        self.assertEqual(sorted(s), [1, 3])
        try:
            s.remove(99)
            self.fail("Expected KeyError")
        except KeyError:
            pass

    def test_discard(self):
        s = {1, 2, 3}
        s.discard(2)
        self.assertEqual(sorted(s), [1, 3])
        s.discard(99)  # should not raise
        self.assertEqual(sorted(s), [1, 3])

    def test_pop(self):
        s = {1}
        v = s.pop()
        self.assertEqual(v, 1)
        self.assertEqual(len(s), 0)
        try:
            s.pop()
            self.fail("Expected KeyError")
        except KeyError:
            pass

    def test_set_literal(self):
        s = {1, 2, 3}
        self.assertEqual(sorted(s), [1, 2, 3])
        self.assertIsInstance(s, set)

    def test_iteration(self):
        s = {1, 2, 3}
        result = []
        for x in s:
            result.append(x)
        self.assertEqual(sorted(result), [1, 2, 3])

    def test_set_of_strings(self):
        s = {'a', 'b', 'c'}
        self.assertEqual(sorted(s), ['a', 'b', 'c'])
        self.assertIn('a', s)
        self.assertNotIn('d', s)

    def test_bool(self):
        self.assertFalse(set())
        self.assertTrue({1})

    def test_repr(self):
        # Empty set
        self.assertEqual(repr(set()), 'set()')
        # Single element
        self.assertEqual(repr({1}), '{1}')

    def test_large_set(self):
        s = set()
        for i in range(1000):
            s.add(i)
        self.assertEqual(len(s), 1000)
        for i in range(1000):
            self.assertIn(i, s)

    def test_update(self):
        s = {1, 2}
        s.update({3, 4})
        self.assertEqual(sorted(s), [1, 2, 3, 4])
        # No-arg update is a no-op
        s.update()
        self.assertEqual(sorted(s), [1, 2, 3, 4])

    def test_set_from_list(self):
        s = set([1, 2, 3, 2, 1])
        self.assertEqual(sorted(s), [1, 2, 3])

    def test_set_from_string(self):
        s = set('abcabc')
        self.assertEqual(sorted(s), ['a', 'b', 'c'])

    def test_frozenset_basic(self):
        fs = frozenset([1, 2, 3])
        self.assertEqual(sorted(fs), [1, 2, 3])
        self.assertIn(1, fs)
        self.assertNotIn(4, fs)
        self.assertEqual(len(fs), 3)

    def test_frozenset_equality(self):
        self.assertEqual(frozenset(), frozenset())
        self.assertEqual(frozenset([1, 2]), frozenset([2, 1]))
        self.assertNotEqual(frozenset([1]), frozenset([1, 2]))

    def test_mixed_set_frozenset_equality(self):
        self.assertEqual({1, 2, 3}, frozenset([1, 2, 3]))
        self.assertEqual(frozenset([1, 2, 3]), {1, 2, 3})


if __name__ == "__main__":
    unittest.main()
