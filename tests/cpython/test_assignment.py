"""Tests for various assignment forms"""

import unittest


class SimpleAssignTest(unittest.TestCase):

    def test_basic(self):
        x = 42
        self.assertEqual(x, 42)

    def test_multiple_targets(self):
        a = b = c = 10
        self.assertEqual(a, 10)
        self.assertEqual(b, 10)
        self.assertEqual(c, 10)

    def test_tuple_assign(self):
        a, b = 1, 2
        self.assertEqual(a, 1)
        self.assertEqual(b, 2)

    def test_list_assign(self):
        [a, b, c] = [4, 5, 6]
        self.assertEqual((a, b, c), (4, 5, 6))

    def test_swap(self):
        a, b = 1, 2
        a, b = b, a
        self.assertEqual(a, 2)
        self.assertEqual(b, 1)

    def test_chained(self):
        x = y = z = []
        x.append(1)
        self.assertEqual(y, [1])
        self.assertEqual(z, [1])
        self.assertIs(x, y)


class AugmentedAssignTest(unittest.TestCase):

    def test_iadd(self):
        x = 10
        x += 5
        self.assertEqual(x, 15)

    def test_isub(self):
        x = 10
        x -= 3
        self.assertEqual(x, 7)

    def test_imul(self):
        x = 4
        x *= 3
        self.assertEqual(x, 12)

    def test_ifloordiv(self):
        x = 10
        x //= 3
        self.assertEqual(x, 3)

    def test_imod(self):
        x = 10
        x %= 3
        self.assertEqual(x, 1)

    def test_ipow(self):
        x = 2
        x **= 10
        self.assertEqual(x, 1024)

    def test_iand(self):
        x = 0xFF
        x &= 0x0F
        self.assertEqual(x, 0x0F)

    def test_ior(self):
        x = 0x0F
        x |= 0xF0
        self.assertEqual(x, 0xFF)

    def test_ixor(self):
        x = 0xFF
        x ^= 0x0F
        self.assertEqual(x, 0xF0)

    def test_ilshift(self):
        x = 1
        x <<= 10
        self.assertEqual(x, 1024)

    def test_irshift(self):
        x = 1024
        x >>= 10
        self.assertEqual(x, 1)

    def test_iadd_list(self):
        x = [1, 2]
        y = x
        x += [3, 4]
        self.assertEqual(x, [1, 2, 3, 4])
        self.assertIs(x, y)  # list += modifies in place

    def test_iadd_string(self):
        x = "hello"
        x += " world"
        self.assertEqual(x, "hello world")

    def test_imul_list(self):
        x = [1, 2]
        x *= 3
        self.assertEqual(x, [1, 2, 1, 2, 1, 2])


class SubscriptAssignTest(unittest.TestCase):

    def test_list_index(self):
        a = [0, 0, 0]
        a[0] = 1
        a[2] = 3
        self.assertEqual(a, [1, 0, 3])

    def test_list_negative(self):
        a = [1, 2, 3]
        a[-1] = 99
        self.assertEqual(a, [1, 2, 99])

    def test_list_slice(self):
        a = [1, 2, 3, 4, 5]
        a[1:3] = [20, 30]
        self.assertEqual(a, [1, 20, 30, 4, 5])

    def test_dict_assign(self):
        d = {}
        d['key'] = 'value'
        self.assertEqual(d['key'], 'value')

    def test_nested_assign(self):
        a = [[0, 0], [0, 0]]
        a[0][1] = 42
        self.assertEqual(a[0][1], 42)


class AttributeAssignTest(unittest.TestCase):

    def test_instance_attr(self):
        class C:
            pass
        obj = C()
        obj.x = 42
        self.assertEqual(obj.x, 42)

    def test_overwrite(self):
        class C:
            pass
        obj = C()
        obj.x = 1
        obj.x = 2
        self.assertEqual(obj.x, 2)

    def test_multiple_attrs(self):
        class C:
            pass
        obj = C()
        obj.a = 1
        obj.b = 2
        obj.c = 3
        self.assertEqual(obj.a + obj.b + obj.c, 6)


if __name__ == "__main__":
    unittest.main()
