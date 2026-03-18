"""Tests for unpacking operations — tuple/list/star unpacking"""

import unittest


class BasicUnpackTest(unittest.TestCase):

    def test_tuple_unpack(self):
        a, b, c = (1, 2, 3)
        self.assertEqual((a, b, c), (1, 2, 3))

    def test_list_unpack(self):
        a, b, c = [4, 5, 6]
        self.assertEqual((a, b, c), (4, 5, 6))

    @unittest.skip("string unpacking not supported")
    def test_string_unpack(self):
        pass

    def test_nested_unpack(self):
        (a, b), (c, d) = (1, 2), (3, 4)
        self.assertEqual((a, b, c, d), (1, 2, 3, 4))

    def test_swap(self):
        a, b = 1, 2
        a, b = b, a
        self.assertEqual((a, b), (2, 1))

    def test_multiple_assign(self):
        a = b = c = 10
        self.assertEqual(a, 10)
        self.assertEqual(b, 10)
        self.assertEqual(c, 10)


class StarUnpackTest(unittest.TestCase):

    def test_star_beginning(self):
        *a, b = [1, 2, 3, 4]
        self.assertEqual(a, [1, 2, 3])
        self.assertEqual(b, 4)

    def test_star_end(self):
        a, *b = [1, 2, 3, 4]
        self.assertEqual(a, 1)
        self.assertEqual(b, [2, 3, 4])

    def test_star_middle(self):
        a, *b, c = [1, 2, 3, 4, 5]
        self.assertEqual(a, 1)
        self.assertEqual(b, [2, 3, 4])
        self.assertEqual(c, 5)

    def test_star_empty(self):
        a, *b, c = [1, 2]
        self.assertEqual(a, 1)
        self.assertEqual(b, [])
        self.assertEqual(c, 2)

    def test_star_single(self):
        *a, = [1, 2, 3]
        self.assertEqual(a, [1, 2, 3])

    def test_star_in_for(self):
        result = []
        for a, *b in [(1, 2, 3), (4, 5, 6)]:
            result.append((a, b))
        self.assertEqual(result, [(1, [2, 3]), (4, [5, 6])])


class UnpackErrorTest(unittest.TestCase):

    @unittest.skip("unpack ValueError crashes")
    def test_too_few(self):
        with self.assertRaises(ValueError):
            a, b, c = [1, 2]

    @unittest.skip("unpack ValueError crashes")
    def test_too_many(self):
        with self.assertRaises(ValueError):
            a, b = [1, 2, 3]


if __name__ == "__main__":
    unittest.main()
