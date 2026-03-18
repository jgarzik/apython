"""Tests for string formatting — f-strings and basic %"""

import unittest


class FStringTest(unittest.TestCase):

    def test_simple(self):
        x = 42
        self.assertEqual(f"{x}", "42")

    def test_expression(self):
        self.assertEqual(f"{2 + 3}", "5")
        self.assertEqual(f"{len('abc')}", "3")

    def test_string_expr(self):
        self.assertEqual(f"{'hello'}", "hello")

    def test_multiple(self):
        a, b = 1, 2
        self.assertEqual(f"{a} + {b} = {a + b}", "1 + 2 = 3")

    def test_nested_quotes(self):
        name = "world"
        self.assertEqual(f"hello {name}!", "hello world!")

    def test_repr_conversion(self):
        self.assertEqual(f"{'hi'!r}", "'hi'")

    def test_str_conversion(self):
        self.assertEqual(f"{42!s}", "42")

    def test_empty_fstring(self):
        self.assertEqual(f"", "")

    def test_no_expressions(self):
        self.assertEqual(f"plain text", "plain text")

    def test_adjacent(self):
        x = 1
        self.assertEqual(f"{x}{x}{x}", "111")


class PercentFormatTest(unittest.TestCase):

    def test_string(self):
        self.assertEqual("hello %s" % "world", "hello world")

    def test_int(self):
        self.assertEqual("%d items" % 5, "5 items")

    def test_repr(self):
        self.assertEqual("%r" % "test", "'test'")

    def test_multiple(self):
        self.assertEqual("%s=%d" % ("x", 42), "x=42")

    def test_hex(self):
        self.assertEqual("%x" % 255, "ff")


class StrMethodsTest(unittest.TestCase):

    def test_join(self):
        self.assertEqual(", ".join(["a", "b", "c"]), "a, b, c")

    def test_split(self):
        self.assertEqual("a,b,c".split(","), ["a", "b", "c"])
        self.assertEqual("  hello  world  ".split(), ["hello", "world"])

    def test_replace(self):
        self.assertEqual("aabbcc".replace("bb", "XX"), "aaXXcc")

    def test_strip(self):
        self.assertEqual("  hi  ".strip(), "hi")

    def test_upper_lower(self):
        self.assertEqual("Hello".upper(), "HELLO")
        self.assertEqual("Hello".lower(), "hello")

    def test_startswith_endswith(self):
        self.assertTrue("hello".startswith("hel"))
        self.assertTrue("hello".endswith("llo"))

    def test_find_count(self):
        self.assertEqual("hello".find("ll"), 2)
        self.assertEqual("hello".find("zz"), -1)
        self.assertEqual("banana".count("an"), 2)

    def test_isdigit_isalpha(self):
        self.assertTrue("123".isdigit())
        self.assertFalse("12a".isdigit())
        self.assertTrue("abc".isalpha())

    def test_zfill(self):
        self.assertEqual("42".zfill(5), "00042")


if __name__ == "__main__":
    unittest.main()
