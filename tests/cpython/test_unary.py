"""Test compiler changes for unary ops (+, -, ~) introduced in Python 2.2"""

import unittest

class UnaryOpTestCase(unittest.TestCase):

    def test_negative(self):
        self.assertTrue(-2 == 0 - 2)
        self.assertEqual(-0, 0)
        self.assertEqual(--2, 2)
        self.assertTrue(-2.0 == 0 - 2.0)

    def test_positive(self):
        self.assertEqual(+2, 2)
        self.assertEqual(+0, 0)
        self.assertEqual(++2, 2)
        self.assertEqual(+2.0, 2.0)

    def test_invert(self):
        self.assertTrue(~2 == -(2+1))
        self.assertEqual(~0, -1)
        self.assertEqual(~~2, 2)

    def test_negation_of_exponentiation(self):
        # Make sure '**' does the right thing; these form a
        # regression test for SourceForge bug #456756.
        self.assertEqual(-2 ** 3, -8)
        self.assertEqual((-2) ** 3, -8)
        self.assertEqual(-2 ** 4, -16)
        self.assertEqual((-2) ** 4, 16)


if __name__ == "__main__":
    unittest.main()
