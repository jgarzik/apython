"""Tests for builtin exception types and their relationships"""

import unittest


class ExceptionTypeTest(unittest.TestCase):

    def test_base_hierarchy(self):
        self.assertTrue(issubclass(Exception, BaseException))
        self.assertTrue(issubclass(TypeError, Exception))
        self.assertTrue(issubclass(ValueError, Exception))
        self.assertTrue(issubclass(KeyError, LookupError))
        self.assertTrue(issubclass(IndexError, LookupError))
        self.assertTrue(issubclass(LookupError, Exception))
        self.assertTrue(issubclass(NotImplementedError, RuntimeError))
        self.assertTrue(issubclass(ZeroDivisionError, ArithmeticError))
        self.assertTrue(issubclass(OverflowError, ArithmeticError))

    def test_keyboard_interrupt(self):
        self.assertTrue(issubclass(KeyboardInterrupt, BaseException))
        self.assertFalse(issubclass(KeyboardInterrupt, Exception))

    def test_exception_args_single(self):
        e = ValueError("msg")
        self.assertEqual(e.args, ("msg",))
        self.assertEqual(str(e), "msg")

    def test_exception_args_multi(self):
        e = ValueError(1, 2, 3)
        self.assertEqual(e.args, (1, 2, 3))
        self.assertEqual(len(e.args), 3)

    def test_exception_args_empty(self):
        e = ValueError()
        self.assertEqual(e.args, ())

    def test_catch_parent(self):
        for ExcType in [TypeError, ValueError, KeyError, IndexError]:
            try:
                raise ExcType("test")
            except Exception:
                pass  # should catch all
            else:
                self.fail("%s not caught by Exception" % ExcType.__name__)

    def test_catch_specific(self):
        caught = None
        try:
            raise KeyError("k")
        except ValueError:
            caught = "ValueError"
        except KeyError:
            caught = "KeyError"
        except TypeError:
            caught = "TypeError"
        self.assertEqual(caught, "KeyError")

    def test_catch_tuple(self):
        for ExcType in [ValueError, TypeError, KeyError]:
            try:
                raise ExcType()
            except (ValueError, TypeError, KeyError):
                pass
            else:
                self.fail("%s not caught by tuple" % ExcType.__name__)


class ErrorRaisingTest(unittest.TestCase):

    def test_type_error(self):
        with self.assertRaises(TypeError):
            len(42)

    def test_value_error(self):
        with self.assertRaises(ValueError):
            int("not_a_number")

    def test_index_error(self):
        with self.assertRaises(IndexError):
            [1, 2, 3][10]

    def test_key_error(self):
        with self.assertRaises(KeyError):
            {}["missing"]

    def test_attribute_error(self):
        with self.assertRaises(AttributeError):
            (42).nonexistent

    def test_zero_division(self):
        with self.assertRaises(ZeroDivisionError):
            1 / 0
        with self.assertRaises(ZeroDivisionError):
            1 // 0

    def test_name_error(self):
        def f():
            return undefined_name
        with self.assertRaises(NameError):
            f()

    def test_stop_iteration(self):
        it = iter([])
        with self.assertRaises(StopIteration):
            next(it)


if __name__ == "__main__":
    unittest.main()
