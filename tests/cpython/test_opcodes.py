"""Tests for various opcode behaviors — adapted from CPython test_opcodes.py"""

import unittest


class OpcodeTest(unittest.TestCase):

    def test_try_inside_for_loop(self):
        n = 0
        for i in range(10):
            n = n + i
            try:
                1 / 0
            except NameError:
                pass
            except ZeroDivisionError:
                pass
            except TypeError:
                pass
            try:
                pass
            except:
                pass
            try:
                pass
            finally:
                pass
            n = n + i
        self.assertEqual(n, 90)

    def test_raise_class_exceptions(self):
        class AClass(Exception):
            pass
        class BClass(AClass):
            pass
        class CClass(Exception):
            pass
        class DClass(AClass):
            def __init__(self, ignore):
                pass

        try:
            raise AClass()
        except:
            pass

        try:
            raise AClass()
        except AClass:
            pass

        try:
            raise BClass()
        except AClass:
            pass

        try:
            raise BClass()
        except CClass:
            self.fail()
        except:
            pass

        a = AClass()
        b = BClass()

        try:
            raise b
        except AClass as v:
            self.assertEqual(v, b)
        else:
            self.fail("no exception")

        try:
            raise DClass(a)
        except DClass as v:
            self.assertIsInstance(v, DClass)
        else:
            self.fail("no exception")

    def test_unpack_sequence(self):
        a, b = 1, 2
        self.assertEqual(a, 1)
        self.assertEqual(b, 2)

        a, b, c = [4, 5, 6]
        self.assertEqual(a, 4)
        self.assertEqual(b, 5)
        self.assertEqual(c, 6)

        a, *b = [1, 2, 3, 4]
        self.assertEqual(a, 1)
        self.assertEqual(b, [2, 3, 4])

        *a, b = [1, 2, 3, 4]
        self.assertEqual(a, [1, 2, 3])
        self.assertEqual(b, 4)

        a, *b, c = [1, 2, 3, 4, 5]
        self.assertEqual(a, 1)
        self.assertEqual(b, [2, 3, 4])
        self.assertEqual(c, 5)

    def test_build_ops(self):
        # BUILD_LIST, BUILD_TUPLE, BUILD_SET, BUILD_MAP
        self.assertEqual([1, 2, 3], [1, 2, 3])
        self.assertEqual((1, 2, 3), (1, 2, 3))
        self.assertEqual({1, 2, 3}, {1, 2, 3})
        self.assertEqual({1: 'a', 2: 'b'}, {1: 'a', 2: 'b'})

    def test_format_value(self):
        x = 42
        self.assertEqual(f"{x}", "42")
        self.assertEqual(f"val={x}", "val=42")
        name = "world"
        self.assertEqual(f"hello {name}", "hello world")

    def test_delete_name(self):
        x = 42
        del x
        with self.assertRaises(UnboundLocalError):
            x  # should raise

    def test_multiple_assignment(self):
        a = b = c = 10
        self.assertEqual(a, 10)
        self.assertEqual(b, 10)
        self.assertEqual(c, 10)

    def test_augmented_assignment(self):
        x = 10
        x += 5
        self.assertEqual(x, 15)
        x -= 3
        self.assertEqual(x, 12)
        x *= 2
        self.assertEqual(x, 24)
        x //= 5
        self.assertEqual(x, 4)
        x **= 3
        self.assertEqual(x, 64)
        x %= 10
        self.assertEqual(x, 4)

    def test_conditional_expression(self):
        x = 1 if True else 2
        self.assertEqual(x, 1)
        x = 1 if False else 2
        self.assertEqual(x, 2)

    def test_chained_comparison(self):
        self.assertTrue(1 < 2 < 3)
        self.assertFalse(1 < 2 > 3)
        self.assertTrue(1 <= 2 <= 2)
        self.assertTrue(3 > 2 > 1)

    def test_boolean_operators(self):
        self.assertEqual(1 or 2, 1)
        self.assertEqual(0 or 2, 2)
        self.assertEqual(1 and 2, 2)
        self.assertEqual(0 and 2, 0)
        self.assertEqual(not True, False)
        self.assertEqual(not False, True)
        self.assertEqual(not 0, True)
        self.assertEqual(not 1, False)


if __name__ == '__main__':
    unittest.main()
