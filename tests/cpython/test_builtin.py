"""Tests for builtin functions — adapted from CPython test_builtin.py"""

import unittest


class BuiltinTest(unittest.TestCase):

    def test_abs(self):
        self.assertEqual(abs(0), 0)
        self.assertEqual(abs(-1), 1)
        self.assertEqual(abs(1), 1)
        self.assertAlmostEqual(abs(-1.5), 1.5)

    def test_bool(self):
        self.assertIs(bool(0), False)
        self.assertIs(bool(1), True)
        self.assertIs(bool(""), False)
        self.assertIs(bool("x"), True)
        self.assertIs(bool([]), False)
        self.assertIs(bool([1]), True)
        self.assertIs(bool(None), False)

    def test_chr_ord(self):
        self.assertEqual(chr(65), 'A')
        self.assertEqual(chr(97), 'a')
        self.assertEqual(ord('A'), 65)
        self.assertEqual(ord('a'), 97)

    def test_divmod(self):
        self.assertEqual(divmod(7, 3), (2, 1))
        self.assertEqual(divmod(-7, 3), (-3, 2))
        self.assertEqual(divmod(7, -3), (-3, -2))

    def test_hash(self):
        self.assertEqual(hash(42), hash(42))
        self.assertEqual(hash("hello"), hash("hello"))
        self.assertIsInstance(hash(42), int)

    def test_hex_oct_bin(self):
        self.assertEqual(hex(255), '0xff')
        self.assertEqual(hex(-1), '-0x1')
        self.assertEqual(oct(8), '0o10')
        self.assertEqual(bin(10), '0b1010')

    def test_id(self):
        a = [1, 2]
        b = a
        c = [1, 2]
        self.assertEqual(id(a), id(b))
        self.assertNotEqual(id(a), id(c))

    def test_int(self):
        self.assertEqual(int(), 0)
        self.assertEqual(int(3.5), 3)
        self.assertEqual(int("42"), 42)
        self.assertEqual(int("-10"), -10)
        self.assertEqual(int("ff", 16), 255)
        self.assertEqual(int("10", 2), 2)

    def test_isinstance_issubclass(self):
        self.assertTrue(isinstance(1, int))
        self.assertTrue(isinstance("x", str))
        self.assertTrue(isinstance([], list))
        self.assertTrue(issubclass(bool, int))
        self.assertFalse(issubclass(str, int))

    def test_len(self):
        self.assertEqual(len([]), 0)
        self.assertEqual(len([1, 2, 3]), 3)
        self.assertEqual(len("hello"), 5)
        self.assertEqual(len({}), 0)
        self.assertEqual(len({1: 2}), 1)

    def test_max_min(self):
        self.assertEqual(max(1, 2, 3), 3)
        self.assertEqual(min(1, 2, 3), 1)
        self.assertEqual(max([1, 2, 3]), 3)
        self.assertEqual(min([1, 2, 3]), 1)

    def test_pow(self):
        self.assertEqual(pow(2, 10), 1024)
        self.assertEqual(pow(3, 3, 8), 3)

    def test_range(self):
        self.assertEqual(list(range(5)), [0, 1, 2, 3, 4])
        self.assertEqual(list(range(1, 5)), [1, 2, 3, 4])
        self.assertEqual(list(range(0, 10, 2)), [0, 2, 4, 6, 8])
        self.assertEqual(list(range(5, 0, -1)), [5, 4, 3, 2, 1])

    def test_repr(self):
        self.assertEqual(repr(42), '42')
        self.assertEqual(repr("hello"), "'hello'")
        self.assertEqual(repr([1, 2]), '[1, 2]')
        self.assertEqual(repr(None), 'None')

    def test_round(self):
        self.assertEqual(round(3.5), 4)
        self.assertEqual(round(4.5), 4)  # banker's rounding
        self.assertEqual(round(3.14159, 2), 3.14)

    def test_sorted(self):
        self.assertEqual(sorted([3, 1, 2]), [1, 2, 3])
        self.assertEqual(sorted("cba"), ['a', 'b', 'c'])
        self.assertEqual(sorted([3, 1, 2], reverse=True), [3, 2, 1])

    def test_str(self):
        self.assertEqual(str(42), '42')
        self.assertEqual(str(3.14), '3.14')
        self.assertEqual(str(True), 'True')
        self.assertEqual(str(None), 'None')
        self.assertEqual(str([1, 2]), '[1, 2]')

    def test_sum(self):
        self.assertEqual(sum([1, 2, 3]), 6)
        self.assertEqual(sum([], 10), 10)
        self.assertEqual(sum(range(10)), 45)

    def test_type(self):
        self.assertIs(type(42), int)
        self.assertIs(type("x"), str)
        self.assertIs(type([]), list)
        self.assertIs(type({}), dict)
        self.assertIs(type(()), tuple)
        self.assertIs(type(True), bool)
        self.assertIs(type(None), type(None))

    def test_zip(self):
        self.assertEqual(list(zip([1, 2], [3, 4])), [(1, 3), (2, 4)])
        self.assertEqual(list(zip()), [])
        self.assertEqual(list(zip([1])), [(1,)])

    def test_enumerate(self):
        self.assertEqual(list(enumerate('ab')), [(0, 'a'), (1, 'b')])
        self.assertEqual(list(enumerate('ab', 5)), [(5, 'a'), (6, 'b')])

    def test_map_filter(self):
        self.assertEqual(list(map(str, [1, 2, 3])), ['1', '2', '3'])
        self.assertEqual(list(filter(lambda x: x > 2, [1, 2, 3, 4])), [3, 4])

    def test_callable(self):
        self.assertTrue(callable(len))
        self.assertTrue(callable(lambda: None))
        self.assertFalse(callable(42))


if __name__ == "__main__":
    unittest.main()
