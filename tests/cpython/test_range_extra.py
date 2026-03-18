"""Tests for range objects"""

import unittest


class RangeTest(unittest.TestCase):

    def test_basic(self):
        self.assertEqual(list(range(5)), [0, 1, 2, 3, 4])

    def test_start_stop(self):
        self.assertEqual(list(range(2, 5)), [2, 3, 4])

    def test_step(self):
        self.assertEqual(list(range(0, 10, 2)), [0, 2, 4, 6, 8])

    def test_negative_step(self):
        self.assertEqual(list(range(5, 0, -1)), [5, 4, 3, 2, 1])
        self.assertEqual(list(range(10, 0, -3)), [10, 7, 4, 1])

    def test_empty(self):
        self.assertEqual(list(range(0)), [])
        self.assertEqual(list(range(5, 5)), [])
        self.assertEqual(list(range(5, 0)), [])

    def test_single(self):
        self.assertEqual(list(range(1)), [0])
        self.assertEqual(list(range(3, 4)), [3])

    def test_len(self):
        self.assertEqual(len(range(10)), 10)
        self.assertEqual(len(range(0)), 0)
        self.assertEqual(len(range(5, 10)), 5)
        self.assertEqual(len(range(0, 10, 3)), 4)

    def test_in_for(self):
        total = 0
        for i in range(10):
            total += i
        self.assertEqual(total, 45)

    def test_contains(self):
        r = range(10)
        self.assertIn(5, r)
        self.assertNotIn(10, r)
        self.assertNotIn(-1, r)

    def test_reversed(self):
        self.assertEqual(list(reversed(range(5))), [4, 3, 2, 1, 0])

    def test_enumerate(self):
        result = list(enumerate(range(3)))
        self.assertEqual(result, [(0, 0), (1, 1), (2, 2)])

    def test_sum(self):
        self.assertEqual(sum(range(100)), 4950)

    def test_negative_range(self):
        self.assertEqual(list(range(-3, 3)), [-3, -2, -1, 0, 1, 2])


if __name__ == "__main__":
    unittest.main()
