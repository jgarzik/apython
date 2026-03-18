"""Tests for walrus operator (:=) — assignment expressions"""

import unittest


class WalrusTest(unittest.TestCase):

    def test_basic(self):
        if (n := 10) > 5:
            result = n
        self.assertEqual(result, 10)

    def test_in_while(self):
        data = [1, 2, 3, 0, 4, 5]
        idx = 0
        result = []
        while (val := data[idx]) != 0:
            result.append(val)
            idx += 1
        self.assertEqual(result, [1, 2, 3])

    def test_in_list_comp(self):
        results = [y for x in range(5) if (y := x * x) > 5]
        self.assertEqual(results, [9, 16])

    def test_in_expression(self):
        x = [y := 42]
        self.assertEqual(x, [42])
        self.assertEqual(y, 42)

    def test_nested(self):
        a = (b := (c := 5) + 1) + 2
        self.assertEqual(c, 5)
        self.assertEqual(b, 6)
        self.assertEqual(a, 8)


if __name__ == "__main__":
    unittest.main()
