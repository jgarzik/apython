"""Tests for string operations — adapted from CPython test_string.py"""

import unittest


class StringFormattingTest(unittest.TestCase):

    def test_fstring_basic(self):
        x = 42
        self.assertEqual(f"{x}", "42")
        self.assertEqual(f"val={x}", "val=42")
        self.assertEqual(f"{x + 1}", "43")

    def test_fstring_expressions(self):
        self.assertEqual(f"{2 + 3}", "5")
        self.assertEqual(f"{'hello'}", "hello")
        self.assertEqual(f"{len('abc')}", "3")

    def test_fstring_nested(self):
        name = "world"
        self.assertEqual(f"hello {name}!", "hello world!")
        self.assertEqual(f"{'hello'} {'world'}", "hello world")

    def test_percent_format(self):
        self.assertEqual("hello %s" % "world", "hello world")
        self.assertEqual("%d items" % 5, "5 items")
        self.assertEqual("%r" % "test", "'test'")

    def test_percent_tuple(self):
        self.assertEqual("%s and %s" % ("foo", "bar"), "foo and bar")
        self.assertEqual("%d + %d = %d" % (1, 2, 3), "1 + 2 = 3")


class StringMethodTest(unittest.TestCase):

    def test_upper_lower(self):
        self.assertEqual("hello".upper(), "HELLO")
        self.assertEqual("HELLO".lower(), "hello")

    def test_strip(self):
        self.assertEqual("  hello  ".strip(), "hello")
        self.assertEqual("  hello  ".lstrip(), "hello  ")
        self.assertEqual("  hello  ".rstrip(), "  hello")

    def test_split_join(self):
        self.assertEqual("a,b,c".split(","), ["a", "b", "c"])
        self.assertEqual(",".join(["a", "b", "c"]), "a,b,c")
        self.assertEqual("hello world".split(), ["hello", "world"])

    def test_find_replace(self):
        self.assertEqual("hello".find("ll"), 2)
        self.assertEqual("hello".find("xx"), -1)
        self.assertEqual("hello".replace("ll", "LL"), "heLLo")

    def test_startswith_endswith(self):
        self.assertTrue("hello".startswith("hel"))
        self.assertFalse("hello".startswith("xyz"))
        self.assertTrue("hello".endswith("llo"))
        self.assertFalse("hello".endswith("xyz"))

    def test_count(self):
        self.assertEqual("hello".count("l"), 2)
        self.assertEqual("hello".count("x"), 0)

    def test_isdigit_isalpha(self):
        self.assertTrue("123".isdigit())
        self.assertFalse("12a".isdigit())
        self.assertTrue("abc".isalpha())
        self.assertFalse("ab1".isalpha())

    def test_zfill(self):
        self.assertEqual("42".zfill(5), "00042")
        self.assertEqual("-42".zfill(5), "-0042")

    def test_center_ljust_rjust(self):
        self.assertEqual("hi".center(6), "  hi  ")
        self.assertEqual("hi".ljust(6), "hi    ")
        self.assertEqual("hi".rjust(6), "    hi")

    def test_encode(self):
        self.assertEqual("hello".encode(), b"hello")
        self.assertIsInstance("hello".encode(), bytes)


class StringSlicingTest(unittest.TestCase):

    def test_indexing(self):
        s = "hello"
        self.assertEqual(s[0], "h")
        self.assertEqual(s[-1], "o")
        self.assertEqual(s[1], "e")

    def test_slicing(self):
        s = "hello"
        self.assertEqual(s[1:3], "el")
        self.assertEqual(s[:3], "hel")
        self.assertEqual(s[3:], "lo")
        self.assertEqual(s[:], "hello")
        self.assertEqual(s[::2], "hlo")
        self.assertEqual(s[::-1], "olleh")

    def test_len(self):
        self.assertEqual(len(""), 0)
        self.assertEqual(len("hello"), 5)

    def test_in(self):
        self.assertIn("ell", "hello")
        self.assertNotIn("xyz", "hello")
        self.assertIn("", "hello")

    def test_concatenation(self):
        self.assertEqual("hello" + " " + "world", "hello world")
        self.assertEqual("ab" * 3, "ababab")

    def test_comparison(self):
        self.assertTrue("abc" < "abd")
        self.assertTrue("abc" == "abc")
        self.assertTrue("abc" != "xyz")
        self.assertTrue("abc" <= "abc")


if __name__ == "__main__":
    unittest.main()
