"""Tests for assert statement"""

import unittest


class AssertTest(unittest.TestCase):

    def test_assert_true(self):
        assert True
        assert 1
        assert "nonempty"
        assert [1]

    def test_assert_false(self):
        with self.assertRaises(AssertionError):
            assert False

    def test_assert_zero(self):
        with self.assertRaises(AssertionError):
            assert 0

    def test_assert_none(self):
        with self.assertRaises(AssertionError):
            assert None

    def test_assert_empty(self):
        with self.assertRaises(AssertionError):
            assert ""
        with self.assertRaises(AssertionError):
            assert []
        with self.assertRaises(AssertionError):
            assert {}

    def test_assert_message(self):
        try:
            assert False, "custom message"
        except AssertionError as e:
            self.assertEqual(str(e), "custom message")
        else:
            self.fail("AssertionError not raised")

    def test_assert_expression(self):
        x = 5
        assert x > 0
        assert x < 10
        assert x == 5

    def test_assert_in_function(self):
        def check(x):
            assert x > 0, "must be positive"
            return x * 2
        self.assertEqual(check(5), 10)
        with self.assertRaises(AssertionError):
            check(-1)


if __name__ == "__main__":
    unittest.main()
