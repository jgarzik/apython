"""Tests for comparison operators — adapted from CPython test_compare.py"""

import unittest


class ComparisonSimpleTest(unittest.TestCase):

    def test_int_comparisons(self):
        self.assertTrue(1 < 2)
        self.assertTrue(2 > 1)
        self.assertTrue(1 <= 1)
        self.assertTrue(1 >= 1)
        self.assertTrue(1 == 1)
        self.assertTrue(1 != 2)
        self.assertFalse(1 > 2)
        self.assertFalse(1 == 2)
        self.assertFalse(1 != 1)

    def test_float_comparisons(self):
        self.assertTrue(1.0 < 2.0)
        self.assertTrue(2.0 > 1.0)
        self.assertTrue(1.0 == 1.0)
        self.assertTrue(1.0 != 2.0)

    def test_mixed_int_float(self):
        self.assertTrue(1 == 1.0)
        self.assertTrue(1 < 1.5)
        self.assertTrue(2.0 > 1)
        self.assertTrue(1 != 1.5)

    def test_string_comparisons(self):
        self.assertTrue('a' < 'b')
        self.assertTrue('b' > 'a')
        self.assertTrue('abc' == 'abc')
        self.assertTrue('abc' != 'abd')
        self.assertTrue('abc' < 'abd')
        self.assertTrue('abc' < 'abcd')

    def test_list_comparisons(self):
        self.assertTrue([1, 2] == [1, 2])
        self.assertTrue([1, 2] != [1, 3])
        self.assertTrue([1, 2] < [1, 3])
        self.assertTrue([1, 2] < [1, 2, 3])
        self.assertTrue([1, 3] > [1, 2])

    def test_tuple_comparisons(self):
        self.assertTrue((1, 2) == (1, 2))
        self.assertTrue((1, 2) != (1, 3))
        self.assertTrue((1, 2) < (1, 3))
        self.assertTrue((1, 2) < (1, 2, 3))

    def test_none_comparisons(self):
        self.assertTrue(None == None)
        self.assertFalse(None != None)
        self.assertTrue(None is None)
        self.assertFalse(None is not None)
        self.assertFalse(None == 0)
        self.assertFalse(None == "")
        self.assertFalse(None == [])

    def test_bool_comparisons(self):
        self.assertTrue(True == True)
        self.assertTrue(False == False)
        self.assertTrue(True != False)
        self.assertTrue(True == 1)
        self.assertTrue(False == 0)
        self.assertTrue(True > False)

    def test_identity(self):
        a = [1, 2]
        b = a
        c = [1, 2]
        self.assertTrue(a is b)
        self.assertFalse(a is c)
        self.assertTrue(a is not c)
        self.assertEqual(a, c)

    def test_chained_comparisons(self):
        self.assertTrue(1 < 2 < 3)
        self.assertFalse(1 < 2 > 3)
        self.assertTrue(1 <= 1 < 2)
        self.assertTrue(1 == 1 <= 2)

    def test_ne_defaults_to_not_eq(self):
        class Cmp:
            def __init__(self, arg):
                self.arg = arg
            def __eq__(self, other):
                return self.arg == other

        a = Cmp(1)
        self.assertTrue(a == 1)
        self.assertFalse(a == 2)

    def test_custom_eq(self):
        class C:
            def __init__(self, val):
                self.val = val
            def __eq__(self, other):
                if isinstance(other, C):
                    return self.val == other.val
                return self.val == other
            def __ne__(self, other):
                if isinstance(other, C):
                    return self.val != other.val
                return self.val != other
        self.assertTrue(C(1) == C(1))
        self.assertFalse(C(1) == C(2))
        self.assertTrue(C(1) != C(2))
        self.assertTrue(C(42) == 42)

    def test_custom_ordering(self):
        class C:
            def __init__(self, val):
                self.val = val
            def __lt__(self, other):
                return self.val < other.val
            def __le__(self, other):
                return self.val <= other.val
            def __gt__(self, other):
                return self.val > other.val
            def __ge__(self, other):
                return self.val >= other.val
        self.assertTrue(C(1) < C(2))
        self.assertTrue(C(2) > C(1))
        self.assertTrue(C(1) <= C(1))
        self.assertTrue(C(1) >= C(1))

    def test_set_equality(self):
        self.assertTrue({1, 2, 3} == {3, 2, 1})
        self.assertFalse({1, 2} == {1, 3})

    def test_dict_equality(self):
        self.assertTrue({1: 'a', 2: 'b'} == {2: 'b', 1: 'a'})
        self.assertFalse({1: 'a'} == {1: 'b'})
        self.assertFalse({1: 'a'} == {2: 'a'})


if __name__ == '__main__':
    unittest.main()
