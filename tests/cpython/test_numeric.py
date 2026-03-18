"""Tests for numeric types — int, float, bool edge cases"""

import unittest


class IntEdgeCaseTest(unittest.TestCase):

    def test_zero(self):
        self.assertEqual(0 + 0, 0)
        self.assertEqual(0 * 100, 0)
        self.assertEqual(0 ** 0, 1)

    def test_negative(self):
        self.assertEqual(-(-5), 5)
        self.assertEqual(abs(-42), 42)
        self.assertTrue(-1 < 0)

    def test_large(self):
        big = 10 ** 20
        self.assertEqual(big + 1, 10 ** 20 + 1)
        self.assertEqual(big * 2, 2 * 10 ** 20)

    def test_int_from_string(self):
        self.assertEqual(int("42"), 42)
        self.assertEqual(int("-10"), -10)
        self.assertEqual(int("0"), 0)
        self.assertEqual(int("ff", 16), 255)
        self.assertEqual(int("77", 8), 63)
        self.assertEqual(int("1010", 2), 10)

    def test_int_from_float(self):
        self.assertEqual(int(3.7), 3)
        self.assertEqual(int(-3.7), -3)
        self.assertEqual(int(0.0), 0)

    def test_int_from_bool(self):
        self.assertEqual(int(True), 1)
        self.assertEqual(int(False), 0)

    def test_divmod(self):
        self.assertEqual(divmod(17, 5), (3, 2))
        self.assertEqual(divmod(-17, 5), (-4, 3))
        self.assertEqual(divmod(17, -5), (-4, -3))

    def test_bit_length(self):
        self.assertEqual((0).bit_length(), 0)
        self.assertEqual((1).bit_length(), 1)
        self.assertEqual((255).bit_length(), 8)
        self.assertEqual((-1).bit_length(), 1)


class FloatEdgeCaseTest(unittest.TestCase):

    def test_special_values(self):
        inf = float('inf')
        self.assertTrue(inf > 0)
        self.assertTrue(-inf < 0)
        self.assertTrue(inf == inf)

    def test_nan(self):
        nan = float('nan')
        self.assertFalse(nan == nan)
        self.assertTrue(nan != nan)

    def test_float_from_string(self):
        self.assertEqual(float("3.14"), 3.14)
        self.assertEqual(float("-0.5"), -0.5)
        self.assertEqual(float("0"), 0.0)
        self.assertEqual(float("1e10"), 1e10)

    def test_float_int_equality(self):
        self.assertTrue(1.0 == 1)
        self.assertTrue(0.0 == 0)
        self.assertFalse(1.5 == 1)

    def test_rounding(self):
        self.assertEqual(round(3.14159, 2), 3.14)
        self.assertEqual(round(2.5), 2)  # banker's rounding
        self.assertEqual(round(3.5), 4)


class BoolTest(unittest.TestCase):

    def test_bool_is_int(self):
        self.assertTrue(isinstance(True, int))
        self.assertTrue(isinstance(False, int))
        self.assertTrue(issubclass(bool, int))

    def test_bool_arithmetic(self):
        self.assertEqual(True + True, 2)
        self.assertEqual(True * 10, 10)
        self.assertEqual(False + 1, 1)

    def test_bool_from_values(self):
        self.assertIs(bool(0), False)
        self.assertIs(bool(1), True)
        self.assertIs(bool(""), False)
        self.assertIs(bool("x"), True)
        self.assertIs(bool([]), False)
        self.assertIs(bool([0]), True)
        self.assertIs(bool(None), False)

    def test_bool_operators(self):
        self.assertEqual(True and True, True)
        self.assertEqual(True and False, False)
        self.assertEqual(False or True, True)
        self.assertEqual(False or False, False)
        self.assertEqual(not True, False)
        self.assertEqual(not False, True)


if __name__ == "__main__":
    unittest.main()
