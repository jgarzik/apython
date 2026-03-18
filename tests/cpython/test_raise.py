"""Tests for raise statement — adapted from CPython test_raise.py"""

import unittest


class TestRaise(unittest.TestCase):

    def test_raise_class(self):
        try:
            raise TypeError
        except TypeError:
            pass
        else:
            self.fail("didn't raise TypeError")

    def test_raise_instance(self):
        try:
            raise TypeError("spam")
        except TypeError as e:
            self.assertEqual(str(e), "spam")
        else:
            self.fail("didn't raise TypeError")

    def test_raise_class_catch_base(self):
        try:
            raise ValueError("test")
        except Exception:
            pass
        else:
            self.fail("didn't catch ValueError as Exception")

    def test_raise_reraise(self):
        try:
            try:
                raise TypeError("foo")
            except:
                raise
        except TypeError as e:
            self.assertEqual(str(e), "foo")
        else:
            self.fail("didn't reraise")

    def test_raise_with_args(self):
        try:
            raise ValueError("one", "two")
        except ValueError as e:
            self.assertEqual(e.args, ("one", "two"))

    def test_raise_from_none(self):
        try:
            try:
                raise TypeError("original")
            except TypeError:
                raise ValueError("replacement") from None
        except ValueError as e:
            self.assertEqual(str(e), "replacement")

    def test_except_specific_type(self):
        # Exception type filtering
        try:
            raise ValueError("val")
        except TypeError:
            self.fail("caught wrong type")
        except ValueError:
            pass

    def test_except_tuple(self):
        # Catch multiple exception types
        try:
            raise KeyError("key")
        except (ValueError, KeyError):
            pass
        else:
            self.fail("didn't catch KeyError from tuple")

    def test_finally_with_exception(self):
        hit_finally = False
        try:
            try:
                raise TypeError("inner")
            finally:
                hit_finally = True
        except TypeError:
            pass
        self.assertTrue(hit_finally)

    def test_finally_with_return(self):
        def f():
            try:
                return 1
            finally:
                return 2
        self.assertEqual(f(), 2)

    @unittest.skip("nested reraise after inner except clears current exception")
    def test_nested_reraise(self):
        try:
            try:
                raise ValueError("original")
            except ValueError:
                try:
                    raise TypeError("inner")
                except TypeError:
                    pass
                raise  # re-raises ValueError
        except ValueError as e:
            self.assertEqual(str(e), "original")

    def test_raise_in_except(self):
        try:
            try:
                raise ValueError("first")
            except ValueError:
                raise TypeError("second")
        except TypeError as e:
            self.assertEqual(str(e), "second")

    def test_bare_except(self):
        try:
            raise RuntimeError("test")
        except:
            pass

    def test_exception_subclass(self):
        class MyError(ValueError):
            pass
        try:
            raise MyError("custom")
        except ValueError:
            pass
        else:
            self.fail("MyError not caught by ValueError handler")

    def test_multiple_except_clauses(self):
        for exc_class in (TypeError, ValueError, KeyError):
            try:
                raise exc_class("test")
            except TypeError:
                self.assertEqual(exc_class, TypeError)
            except ValueError:
                self.assertEqual(exc_class, ValueError)
            except KeyError:
                self.assertEqual(exc_class, KeyError)

    @unittest.skip("generator.throw() not fully implemented")
    def test_raise_none_invalid(self):
        # raise None should raise TypeError
        self.assertRaises(TypeError, lambda: (_ for _ in ()).throw(None))


if __name__ == "__main__":
    unittest.main()
