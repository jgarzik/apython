"""Extra exception handling tests"""

import unittest


class ExceptClauseTest(unittest.TestCase):

    def test_bare_except(self):
        caught = False
        try:
            raise ValueError("test")
        except:
            caught = True
        self.assertTrue(caught)

    def test_specific_except(self):
        caught_type = None
        try:
            raise KeyError("k")
        except ValueError:
            caught_type = "ValueError"
        except KeyError:
            caught_type = "KeyError"
        self.assertEqual(caught_type, "KeyError")

    def test_tuple_except(self):
        caught = False
        try:
            raise TypeError("t")
        except (ValueError, TypeError, KeyError):
            caught = True
        self.assertTrue(caught)

    def test_except_as(self):
        try:
            raise ValueError("hello")
        except ValueError as e:
            self.assertEqual(str(e), "hello")

    def test_except_no_match(self):
        with self.assertRaises(TypeError):
            try:
                raise TypeError("t")
            except ValueError:
                pass

    def test_multiple_except_blocks(self):
        results = []
        for exc in [ValueError("v"), TypeError("t"), KeyError("k")]:
            try:
                raise exc
            except ValueError:
                results.append("V")
            except TypeError:
                results.append("T")
            except KeyError:
                results.append("K")
        self.assertEqual(results, ["V", "T", "K"])


class FinallyTest(unittest.TestCase):

    def test_finally_always_runs(self):
        ran = False
        try:
            pass
        finally:
            ran = True
        self.assertTrue(ran)

    def test_finally_after_exception(self):
        ran = False
        try:
            try:
                raise ValueError("v")
            finally:
                ran = True
        except ValueError:
            pass
        self.assertTrue(ran)

    def test_finally_after_return(self):
        result = []
        def f():
            try:
                result.append("try")
                return 42
            finally:
                result.append("finally")
        self.assertEqual(f(), 42)
        self.assertEqual(result, ["try", "finally"])

    def test_finally_after_break(self):
        result = []
        for i in range(5):
            try:
                if i == 2:
                    break
                result.append(i)
            finally:
                result.append("f")
        self.assertEqual(result, [0, "f", 1, "f", "f"])

    def test_nested_finally(self):
        order = []
        try:
            try:
                order.append("inner try")
            finally:
                order.append("inner finally")
        finally:
            order.append("outer finally")
        self.assertEqual(order,
                         ["inner try", "inner finally", "outer finally"])


class RaiseTest(unittest.TestCase):

    def test_raise_class(self):
        with self.assertRaises(ValueError):
            raise ValueError

    def test_raise_instance(self):
        with self.assertRaises(ValueError):
            raise ValueError("message")

    def test_reraise(self):
        try:
            try:
                raise ValueError("original")
            except ValueError:
                raise
        except ValueError as e:
            self.assertEqual(str(e), "original")

    def test_raise_from_none(self):
        try:
            try:
                raise ValueError("cause")
            except:
                raise TypeError("effect") from None
        except TypeError as e:
            self.assertEqual(str(e), "effect")

    def test_exception_in_handler(self):
        try:
            try:
                raise ValueError("first")
            except ValueError:
                raise TypeError("second")
        except TypeError as e:
            self.assertEqual(str(e), "second")

    def test_exception_subclass_catch(self):
        class MyError(RuntimeError):
            pass
        with self.assertRaises(RuntimeError):
            raise MyError("custom")


if __name__ == "__main__":
    unittest.main()
