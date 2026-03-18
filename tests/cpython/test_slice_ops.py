"""Tests for slice operations on sequences"""

import unittest


class ListSliceTest(unittest.TestCase):

    def test_basic_slice(self):
        a = [0, 1, 2, 3, 4]
        self.assertEqual(a[1:3], [1, 2])
        self.assertEqual(a[:3], [0, 1, 2])
        self.assertEqual(a[3:], [3, 4])
        self.assertEqual(a[:], [0, 1, 2, 3, 4])

    def test_negative_index(self):
        a = [0, 1, 2, 3, 4]
        self.assertEqual(a[-2:], [3, 4])
        self.assertEqual(a[:-2], [0, 1, 2])
        self.assertEqual(a[-3:-1], [2, 3])

    def test_step(self):
        a = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
        self.assertEqual(a[::2], [0, 2, 4, 6, 8])
        self.assertEqual(a[1::2], [1, 3, 5, 7, 9])
        self.assertEqual(a[::-1], [9, 8, 7, 6, 5, 4, 3, 2, 1, 0])
        self.assertEqual(a[::-2], [9, 7, 5, 3, 1])

    def test_slice_assign(self):
        a = [0, 1, 2, 3, 4]
        a[1:3] = [10, 20, 30]
        self.assertEqual(a, [0, 10, 20, 30, 3, 4])

    def test_slice_delete(self):
        a = [0, 1, 2, 3, 4]
        del a[1:3]
        self.assertEqual(a, [0, 3, 4])

    def test_empty_slice(self):
        a = [1, 2, 3]
        self.assertEqual(a[5:10], [])
        self.assertEqual(a[-10:-5], [])

    def test_slice_grow(self):
        a = [1, 2, 3]
        a[1:2] = [10, 20, 30, 40]
        self.assertEqual(a, [1, 10, 20, 30, 40, 3])

    def test_slice_shrink(self):
        a = [1, 2, 3, 4, 5]
        a[1:4] = [99]
        self.assertEqual(a, [1, 99, 5])

    def test_extended_slice_assign(self):
        a = list(range(10))
        a[::2] = [-1] * 5
        self.assertEqual(a, [-1, 1, -1, 3, -1, 5, -1, 7, -1, 9])

    def test_extended_slice_delete(self):
        a = list(range(5))
        del a[::2]
        self.assertEqual(a, [1, 3])


class TupleSliceTest(unittest.TestCase):

    def test_basic(self):
        t = (0, 1, 2, 3, 4)
        self.assertEqual(t[1:3], (1, 2))
        self.assertEqual(t[::-1], (4, 3, 2, 1, 0))

    def test_empty(self):
        t = (1, 2, 3)
        self.assertEqual(t[5:], ())


class StringSliceTest(unittest.TestCase):

    def test_basic(self):
        s = "hello"
        self.assertEqual(s[1:3], "el")
        self.assertEqual(s[::-1], "olleh")

    def test_step(self):
        s = "abcdefgh"
        self.assertEqual(s[::2], "aceg")


if __name__ == "__main__":
    unittest.main()
