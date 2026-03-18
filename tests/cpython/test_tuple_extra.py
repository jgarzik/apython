"""Extra tuple tests — adapted from CPython test_tuple.py"""

import unittest


class TupleTest(unittest.TestCase):

    def test_literal(self):
        self.assertEqual((), ())
        self.assertEqual((1,), (1,))
        self.assertEqual((1, 2, 3), (1, 2, 3))

    def test_len(self):
        self.assertEqual(len(()), 0)
        self.assertEqual(len((1, 2, 3)), 3)

    def test_indexing(self):
        t = (1, 2, 3, 4, 5)
        self.assertEqual(t[0], 1)
        self.assertEqual(t[-1], 5)
        self.assertEqual(t[2], 3)

    def test_slicing(self):
        t = (0, 1, 2, 3, 4)
        self.assertEqual(t[1:3], (1, 2))
        self.assertEqual(t[:3], (0, 1, 2))
        self.assertEqual(t[3:], (3, 4))
        self.assertEqual(t[::-1], (4, 3, 2, 1, 0))

    def test_concatenation(self):
        self.assertEqual((1, 2) + (3, 4), (1, 2, 3, 4))
        self.assertEqual(() + (1,), (1,))

    def test_repetition(self):
        self.assertEqual((1, 2) * 3, (1, 2, 1, 2, 1, 2))
        self.assertEqual((0,) * 5, (0, 0, 0, 0, 0))

    def test_contains(self):
        t = (1, 2, 3)
        self.assertIn(2, t)
        self.assertNotIn(4, t)

    def test_comparison(self):
        self.assertTrue((1, 2) == (1, 2))
        self.assertTrue((1, 2) != (1, 3))
        self.assertTrue((1, 2) < (1, 3))
        self.assertTrue((1, 2) < (1, 2, 3))
        self.assertTrue((1, 3) > (1, 2))

    def test_count(self):
        t = (1, 2, 2, 3, 2)
        self.assertEqual(t.count(2), 3)
        self.assertEqual(t.count(4), 0)

    def test_index(self):
        t = (1, 2, 3, 2, 1)
        self.assertEqual(t.index(2), 1)
        self.assertEqual(t.index(3), 2)
        self.assertRaises(ValueError, t.index, 99)

    def test_hash(self):
        self.assertEqual(hash((1, 2)), hash((1, 2)))
        # different tuples may have different hashes (not guaranteed but likely)

    def test_iteration(self):
        result = []
        for x in (10, 20, 30):
            result.append(x)
        self.assertEqual(result, [10, 20, 30])

    def test_unpacking(self):
        a, b, c = (1, 2, 3)
        self.assertEqual(a, 1)
        self.assertEqual(b, 2)
        self.assertEqual(c, 3)

    def test_star_unpacking(self):
        a, *b = (1, 2, 3, 4)
        self.assertEqual(a, 1)
        self.assertEqual(b, [2, 3, 4])
        *a, b = (1, 2, 3, 4)
        self.assertEqual(a, [1, 2, 3])
        self.assertEqual(b, 4)

    def test_constructor(self):
        self.assertEqual(tuple(), ())
        self.assertEqual(tuple([1, 2, 3]), (1, 2, 3))
        self.assertEqual(tuple("abc"), ('a', 'b', 'c'))
        self.assertEqual(tuple(range(5)), (0, 1, 2, 3, 4))

    def test_nested(self):
        t = ((1, 2), (3, 4))
        self.assertEqual(t[0], (1, 2))
        self.assertEqual(t[1][0], 3)

    def test_bool(self):
        self.assertFalse(bool(()))
        self.assertTrue(bool((1,)))

    def test_mixed_types(self):
        t = (1, "two", 3.0, [4], None)
        self.assertEqual(len(t), 5)
        self.assertEqual(t[1], "two")
        self.assertIsNone(t[4])


if __name__ == "__main__":
    unittest.main()
