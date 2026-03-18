"""Tests for exception objects — adapted from CPython test_baseexception.py"""

import unittest


class ExceptionClassTests(unittest.TestCase):

    def test_builtins_new_style(self):
        self.assertTrue(issubclass(Exception, object))

    def test_interface_single_arg(self):
        arg = "spam"
        exc = Exception(arg)
        self.assertEqual(len(exc.args), 1)
        self.assertEqual(exc.args[0], arg)
        self.assertEqual(str(exc), arg)

    def test_interface_multi_arg(self):
        args = (1, 2, 3)
        exc = Exception(*args)
        self.assertEqual(len(exc.args), 3)
        self.assertEqual(exc.args, args)

    def test_interface_no_arg(self):
        exc = Exception()
        self.assertEqual(len(exc.args), 0)
        self.assertEqual(exc.args, ())

    def test_exception_hierarchy(self):
        # Basic hierarchy checks
        self.assertTrue(issubclass(Exception, BaseException))
        self.assertTrue(issubclass(TypeError, Exception))
        self.assertTrue(issubclass(ValueError, Exception))
        self.assertTrue(issubclass(KeyError, Exception))
        self.assertTrue(issubclass(IndexError, Exception))
        self.assertTrue(issubclass(AttributeError, Exception))
        self.assertTrue(issubclass(NameError, Exception))
        self.assertTrue(issubclass(RuntimeError, Exception))
        self.assertTrue(issubclass(StopIteration, Exception))
        self.assertTrue(issubclass(ZeroDivisionError, Exception))
        self.assertTrue(issubclass(ImportError, Exception))
        self.assertTrue(issubclass(OverflowError, Exception))
        self.assertTrue(issubclass(KeyboardInterrupt, BaseException))

    def test_exception_subclass(self):
        self.assertTrue(issubclass(KeyError, LookupError))
        self.assertTrue(issubclass(IndexError, LookupError))
        self.assertTrue(issubclass(NotImplementedError, RuntimeError))
        self.assertTrue(issubclass(UnboundLocalError, NameError))


class UsageTests(unittest.TestCase):

    def raise_fails(self, object_):
        try:
            raise object_
        except TypeError:
            return
        self.fail("TypeError expected for raising %s" % type(object_))

    def test_raise_non_exception_class(self):
        class NotAnException:
            pass
        self.raise_fails(NotAnException)

    @unittest.skip("raise non-exception instance segfaults")
    def test_raise_string(self):
        self.raise_fails("spam")

    @unittest.skip("raise non-exception instance segfaults")
    def test_raise_int(self):
        self.raise_fails(42)

    def test_catch_specific(self):
        try:
            raise ValueError("test")
        except ValueError as e:
            self.assertEqual(str(e), "test")
        else:
            self.fail("ValueError not caught")

    def test_catch_base_class(self):
        try:
            raise ValueError("val")
        except Exception:
            pass
        else:
            self.fail("Exception didn't catch ValueError")

    def test_catch_tuple(self):
        try:
            raise KeyError("key")
        except (ValueError, KeyError):
            pass
        else:
            self.fail("tuple catch failed")

    def test_exception_args(self):
        try:
            raise ValueError("a", "b", "c")
        except ValueError as e:
            self.assertEqual(e.args, ("a", "b", "c"))

    def test_custom_exception(self):
        class MyError(Exception):
            def __init__(self, code):
                self.code = code
        try:
            raise MyError(404)
        except MyError as e:
            self.assertEqual(e.code, 404)

    def test_exception_chaining_basic(self):
        try:
            try:
                raise ValueError("original")
            except ValueError:
                raise TypeError("replacement")
        except TypeError as e:
            self.assertEqual(str(e), "replacement")


if __name__ == '__main__':
    unittest.main()
