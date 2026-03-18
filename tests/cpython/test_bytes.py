"""Tests for bytes — adapted from CPython test_bytes.py"""

import unittest


class BytesTest(unittest.TestCase):

    def test_literal(self):
        self.assertEqual(b"hello", b"hello")
        self.assertEqual(b"", b"")

    def test_len(self):
        self.assertEqual(len(b""), 0)
        self.assertEqual(len(b"hello"), 5)

    def test_indexing(self):
        b = b"hello"
        self.assertEqual(b[0], 104)  # ord('h')
        self.assertEqual(b[-1], 111)  # ord('o')

    def test_slicing(self):
        b = b"hello"
        self.assertEqual(b[1:3], b"el")
        self.assertEqual(b[:3], b"hel")
        self.assertEqual(b[3:], b"lo")

    def test_comparison(self):
        self.assertTrue(b"abc" == b"abc")
        self.assertTrue(b"abc" != b"abd")

    def test_decode(self):
        self.assertEqual(b"hello".decode(), "hello")

    def test_iteration(self):
        result = []
        for x in b"abc":
            result.append(x)
        self.assertEqual(result, [97, 98, 99])

    def test_methods(self):
        self.assertTrue(b"hello".startswith(b"hel"))
        self.assertTrue(b"hello".endswith(b"llo"))
        self.assertEqual(b"hello".find(b"ll"), 2)


if __name__ == "__main__":
    unittest.main()
