"""Tests for pow() and ** operator — adapted from CPython test_pow.py"""

import unittest

class PowTest(unittest.TestCase):

    def test_powint_basic(self):
        """pow(int, 0) == 1 and pow(int, 1) == int"""
        for i in range(-100, 100):
            self.assertEqual(pow(i, 0), 1)
            self.assertEqual(pow(i, 1), i)
            self.assertEqual(pow(0, 1), 0)
            self.assertEqual(pow(1, 1), 1)

    def test_powint_cube(self):
        for i in range(-100, 100):
            self.assertEqual(pow(i, 3), i*i*i)

    def test_powint_powers_of_two(self):
        pow2 = 1
        for i in range(0, 31):
            self.assertEqual(pow(2, i), pow2)
            if i != 30:
                pow2 = pow2 * 2

    def test_pow_operator(self):
        self.assertEqual(2 ** 10, 1024)
        self.assertEqual((-2) ** 3, -8)
        self.assertEqual((-2) ** 4, 16)
        self.assertEqual(3 ** 0, 1)
        self.assertEqual(0 ** 0, 1)

    def test_pow_negation_precedence(self):
        self.assertEqual(-2 ** 3, -8)
        self.assertEqual((-2) ** 3, -8)
        self.assertEqual(-2 ** 4, -16)
        self.assertEqual((-2) ** 4, 16)

    def test_pow_three_arg(self):
        """3-argument pow (modular exponentiation)"""
        self.assertEqual(pow(3, 3, 8), pow(3, 3) % 8)
        self.assertEqual(pow(3, 3, -8), pow(3, 3) % -8)
        self.assertEqual(pow(3, 2, -2), pow(3, 2) % -2)
        self.assertEqual(pow(-3, 3, 8), pow(-3, 3) % 8)
        self.assertEqual(pow(-3, 3, -8), pow(-3, 3) % -8)
        self.assertEqual(pow(5, 2, -8), pow(5, 2) % -8)

    def test_pow_three_arg_systematic(self):
        for i in range(-10, 11):
            for j in range(0, 6):
                for k in range(-7, 11):
                    if j >= 0 and k != 0:
                        self.assertEqual(
                            pow(i, j) % k,
                            pow(i, j, k)
                        )

    def test_pow_float(self):
        self.assertAlmostEqual(pow(2.0, 3.0), 8.0)
        self.assertAlmostEqual(pow(0.5, 2.0), 0.25)
        self.assertEqual(pow(1.0, 100), 1.0)

    def test_pow_big(self):
        self.assertEqual(pow(2, 100), 1 << 100)


if __name__ == "__main__":
    unittest.main()
