"""Tests for basic math operations — int and float arithmetic"""

import unittest


class IntArithTest(unittest.TestCase):

    def test_add(self):
        self.assertEqual(1 + 2, 3)
        self.assertEqual(-1 + 1, 0)
        self.assertEqual(0 + 0, 0)

    def test_sub(self):
        self.assertEqual(5 - 3, 2)
        self.assertEqual(3 - 5, -2)
        self.assertEqual(0 - 0, 0)

    def test_mul(self):
        self.assertEqual(3 * 4, 12)
        self.assertEqual(-2 * 3, -6)
        self.assertEqual(0 * 100, 0)

    def test_truediv(self):
        self.assertEqual(10 / 2, 5.0)
        self.assertEqual(7 / 2, 3.5)
        self.assertEqual(-6 / 3, -2.0)

    def test_floordiv(self):
        self.assertEqual(7 // 2, 3)
        self.assertEqual(-7 // 2, -4)
        self.assertEqual(10 // 3, 3)

    def test_mod(self):
        self.assertEqual(7 % 3, 1)
        self.assertEqual(-7 % 3, 2)
        self.assertEqual(10 % 5, 0)

    def test_pow(self):
        self.assertEqual(2 ** 10, 1024)
        self.assertEqual(3 ** 0, 1)
        self.assertEqual((-2) ** 3, -8)

    def test_neg(self):
        self.assertEqual(-5, -(5))
        self.assertEqual(-(-5), 5)
        self.assertEqual(-0, 0)

    def test_abs(self):
        self.assertEqual(abs(5), 5)
        self.assertEqual(abs(-5), 5)
        self.assertEqual(abs(0), 0)

    def test_divmod(self):
        self.assertEqual(divmod(7, 3), (2, 1))
        self.assertEqual(divmod(-7, 3), (-3, 2))

    def test_bitwise(self):
        self.assertEqual(0xFF & 0x0F, 0x0F)
        self.assertEqual(0x0F | 0xF0, 0xFF)
        self.assertEqual(0xFF ^ 0x0F, 0xF0)
        self.assertEqual(~0, -1)
        self.assertEqual(1 << 10, 1024)
        self.assertEqual(1024 >> 10, 1)

    def test_comparison(self):
        self.assertTrue(1 < 2)
        self.assertTrue(2 > 1)
        self.assertTrue(1 <= 1)
        self.assertTrue(1 >= 1)
        self.assertTrue(1 == 1)
        self.assertTrue(1 != 2)

    def test_large_int(self):
        big = 2 ** 100
        self.assertTrue(big > 0)
        self.assertEqual(big * 2, 2 ** 101)
        self.assertEqual(big // 2, 2 ** 99)


class FloatArithTest(unittest.TestCase):

    def test_add(self):
        self.assertAlmostEqual(0.1 + 0.2, 0.3, places=10)

    def test_sub(self):
        self.assertAlmostEqual(1.0 - 0.3, 0.7, places=10)

    def test_mul(self):
        self.assertAlmostEqual(2.5 * 4.0, 10.0)

    def test_truediv(self):
        self.assertAlmostEqual(10.0 / 3.0, 3.3333333333, places=5)

    def test_floordiv(self):
        self.assertEqual(7.0 // 2.0, 3.0)

    def test_mod(self):
        self.assertAlmostEqual(7.5 % 2.5, 0.0)

    def test_pow(self):
        self.assertAlmostEqual(2.0 ** 0.5, 1.4142135623, places=5)

    def test_neg(self):
        self.assertEqual(-3.14, -(3.14))

    def test_abs(self):
        self.assertEqual(abs(-3.14), 3.14)
        self.assertEqual(abs(3.14), 3.14)

    def test_int_float_mixed(self):
        self.assertEqual(1 + 1.0, 2.0)
        self.assertEqual(2 * 1.5, 3.0)
        self.assertEqual(10 / 4, 2.5)
        self.assertTrue(1 < 1.5)
        self.assertTrue(2.0 == 2)


class BoolArithTest(unittest.TestCase):

    def test_bool_as_int(self):
        self.assertEqual(True + True, 2)
        self.assertEqual(True * 5, 5)
        self.assertEqual(False + 1, 1)
        self.assertEqual(True + 0, 1)

    def test_bool_in_expressions(self):
        self.assertEqual(sum([True, False, True, True]), 3)


if __name__ == "__main__":
    unittest.main()
