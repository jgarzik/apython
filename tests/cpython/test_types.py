"""Tests for type system basics — adapted from CPython test_types.py"""

import unittest


class TypeTest(unittest.TestCase):

    def test_truth_values(self):
        # Falsy values
        self.assertFalse(bool(None))
        self.assertFalse(bool(0))
        self.assertFalse(bool(0.0))
        self.assertFalse(bool(''))
        self.assertFalse(bool([]))
        self.assertFalse(bool(()))
        self.assertFalse(bool({}))
        self.assertFalse(bool(set()))
        self.assertFalse(bool(False))
        self.assertFalse(bool(b''))

        # Truthy values
        self.assertTrue(bool(1))
        self.assertTrue(bool(-1))
        self.assertTrue(bool(0.1))
        self.assertTrue(bool('x'))
        self.assertTrue(bool([0]))
        self.assertTrue(bool((0,)))
        self.assertTrue(bool({0: 0}))
        self.assertTrue(bool({0}))
        self.assertTrue(bool(True))
        self.assertTrue(bool(b'x'))

    def test_none_type(self):
        self.assertIs(type(None), type(None))
        self.assertEqual(repr(None), 'None')
        self.assertEqual(str(None), 'None')

    def test_int_type(self):
        self.assertIs(type(1), int)
        self.assertIs(type(True), bool)
        self.assertTrue(issubclass(bool, int))

    def test_float_type(self):
        self.assertIs(type(1.0), float)

    def test_str_type(self):
        self.assertIs(type(""), str)

    def test_list_type(self):
        self.assertIs(type([]), list)

    def test_dict_type(self):
        self.assertIs(type({}), dict)

    def test_tuple_type(self):
        self.assertIs(type(()), tuple)

    def test_set_type(self):
        self.assertIs(type(set()), set)

    def test_bytes_type(self):
        self.assertIs(type(b""), bytes)

    def test_function_type(self):
        def f(): pass
        self.assertEqual(type(f).__name__, 'function')

    def test_method_type(self):
        class C:
            def f(self): pass
        obj = C()
        self.assertTrue(callable(obj.f))

    def test_type_of_type(self):
        self.assertIs(type(int), type)
        self.assertIs(type(str), type)
        self.assertIs(type(list), type)


class ConversionTest(unittest.TestCase):

    def test_int_conversions(self):
        self.assertEqual(int(3.9), 3)
        self.assertEqual(int(-3.9), -3)
        self.assertEqual(int("100"), 100)
        self.assertEqual(int("0xff", 16), 255)
        self.assertEqual(int(True), 1)
        self.assertEqual(int(False), 0)

    def test_float_conversions(self):
        self.assertEqual(float(3), 3.0)
        self.assertEqual(float("3.14"), 3.14)
        self.assertEqual(float(True), 1.0)
        self.assertEqual(float(False), 0.0)

    def test_str_conversions(self):
        self.assertEqual(str(42), "42")
        self.assertEqual(str(3.14), "3.14")
        self.assertEqual(str(True), "True")
        self.assertEqual(str(False), "False")
        self.assertEqual(str(None), "None")
        self.assertEqual(str([1, 2]), "[1, 2]")
        self.assertEqual(str((1, 2)), "(1, 2)")

    def test_bool_conversions(self):
        self.assertIs(bool(0), False)
        self.assertIs(bool(1), True)
        self.assertIs(bool(""), False)
        self.assertIs(bool("x"), True)

    def test_list_conversions(self):
        self.assertEqual(list("abc"), ['a', 'b', 'c'])
        self.assertEqual(list((1, 2, 3)), [1, 2, 3])
        self.assertEqual(list(range(3)), [0, 1, 2])
        self.assertEqual(list({1, 2, 3}), sorted([1, 2, 3]))

    def test_tuple_conversions(self):
        self.assertEqual(tuple([1, 2, 3]), (1, 2, 3))
        self.assertEqual(tuple("abc"), ('a', 'b', 'c'))
        self.assertEqual(tuple(range(3)), (0, 1, 2))

    def test_set_conversions(self):
        self.assertEqual(set([1, 2, 2, 3]), {1, 2, 3})
        self.assertEqual(frozenset([1, 2, 3]), frozenset({1, 2, 3}))

    @unittest.skip("dict() from kwargs not implemented")
    def test_dict_conversions(self):
        pass


if __name__ == "__main__":
    unittest.main()
