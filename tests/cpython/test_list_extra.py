"""Extra list tests — adapted from CPython test_list.py"""

import unittest


class ListExtraTest(unittest.TestCase):

    def test_literal(self):
        self.assertEqual([], [])
        self.assertEqual([1, 2, 3], [1, 2, 3])

    def test_constructor(self):
        self.assertEqual(list(), [])
        self.assertEqual(list((1, 2, 3)), [1, 2, 3])
        self.assertEqual(list("abc"), ['a', 'b', 'c'])
        self.assertEqual(list(range(5)), [0, 1, 2, 3, 4])

    def test_append_extend(self):
        a = [1]
        a.append(2)
        a.extend([3, 4])
        self.assertEqual(a, [1, 2, 3, 4])

    def test_insert(self):
        a = [1, 3]
        a.insert(1, 2)
        self.assertEqual(a, [1, 2, 3])
        a.insert(0, 0)
        self.assertEqual(a, [0, 1, 2, 3])

    def test_remove(self):
        a = [1, 2, 3, 2]
        a.remove(2)
        self.assertEqual(a, [1, 3, 2])
        self.assertRaises(ValueError, a.remove, 99)

    def test_pop(self):
        a = [1, 2, 3]
        self.assertEqual(a.pop(), 3)
        self.assertEqual(a, [1, 2])
        self.assertEqual(a.pop(0), 1)
        self.assertEqual(a, [2])

    def test_index(self):
        a = [1, 2, 3, 2]
        self.assertEqual(a.index(2), 1)
        self.assertRaises(ValueError, a.index, 99)

    def test_count(self):
        a = [1, 2, 2, 3, 2]
        self.assertEqual(a.count(2), 3)
        self.assertEqual(a.count(4), 0)

    def test_reverse(self):
        a = [1, 2, 3]
        a.reverse()
        self.assertEqual(a, [3, 2, 1])

    def test_sort(self):
        a = [3, 1, 4, 1, 5]
        a.sort()
        self.assertEqual(a, [1, 1, 3, 4, 5])
        a.sort(reverse=True)
        self.assertEqual(a, [5, 4, 3, 1, 1])

    def test_copy(self):
        a = [1, 2, 3]
        b = a.copy()
        self.assertEqual(a, b)
        b.append(4)
        self.assertNotEqual(a, b)

    def test_clear(self):
        a = [1, 2, 3]
        a.clear()
        self.assertEqual(a, [])

    def test_slicing(self):
        a = [0, 1, 2, 3, 4]
        self.assertEqual(a[1:3], [1, 2])
        self.assertEqual(a[::-1], [4, 3, 2, 1, 0])
        self.assertEqual(a[::2], [0, 2, 4])

    def test_slice_assignment(self):
        a = [0, 1, 2, 3, 4]
        a[1:3] = [10, 20, 30]
        self.assertEqual(a, [0, 10, 20, 30, 3, 4])

    def test_del_slice(self):
        a = [0, 1, 2, 3, 4]
        del a[1:3]
        self.assertEqual(a, [0, 3, 4])

    def test_multiply(self):
        self.assertEqual([1, 2] * 3, [1, 2, 1, 2, 1, 2])
        self.assertEqual([0] * 5, [0, 0, 0, 0, 0])

    def test_add(self):
        self.assertEqual([1, 2] + [3, 4], [1, 2, 3, 4])

    def test_iadd(self):
        a = [1, 2]
        a += [3, 4]
        self.assertEqual(a, [1, 2, 3, 4])

    def test_imul(self):
        a = [1, 2]
        a *= 3
        self.assertEqual(a, [1, 2, 1, 2, 1, 2])

    def test_contains(self):
        a = [1, 2, 3]
        self.assertIn(2, a)
        self.assertNotIn(4, a)

    def test_comparison(self):
        self.assertTrue([1, 2] == [1, 2])
        self.assertTrue([1, 2] != [1, 3])
        self.assertTrue([1, 2] < [1, 3])
        self.assertTrue([1, 2] < [1, 2, 3])

    def test_bool(self):
        self.assertFalse(bool([]))
        self.assertTrue(bool([1]))

    def test_nested(self):
        a = [[1, 2], [3, 4]]
        self.assertEqual(a[0][1], 2)
        self.assertEqual(a[1][0], 3)

    def test_comprehension(self):
        self.assertEqual([x**2 for x in range(5)], [0, 1, 4, 9, 16])
        self.assertEqual([x for x in range(10) if x % 2 == 0], [0, 2, 4, 6, 8])

    def test_self_referencing_repr(self):
        a = [1, 2]
        a.append(a)
        self.assertEqual(repr(a), '[1, 2, [...]]')


if __name__ == "__main__":
    unittest.main()
