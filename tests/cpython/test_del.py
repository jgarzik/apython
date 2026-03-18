"""Tests for del statement"""

import unittest


class DelTest(unittest.TestCase):

    def test_del_local(self):
        x = 42
        del x
        with self.assertRaises(UnboundLocalError):
            x

    def test_del_list_item(self):
        a = [1, 2, 3, 4, 5]
        del a[2]
        self.assertEqual(a, [1, 2, 4, 5])

    def test_del_list_slice(self):
        a = [0, 1, 2, 3, 4]
        del a[1:3]
        self.assertEqual(a, [0, 3, 4])

    def test_del_dict_item(self):
        d = {'a': 1, 'b': 2, 'c': 3}
        del d['b']
        self.assertEqual(sorted(d.keys()), ['a', 'c'])

    def test_del_attribute(self):
        class C:
            pass
        obj = C()
        obj.x = 42
        self.assertEqual(obj.x, 42)
        del obj.x
        with self.assertRaises(AttributeError):
            obj.x

    def test_del_multiple(self):
        a = 1
        b = 2
        c = 3
        del a, b
        self.assertEqual(c, 3)
        with self.assertRaises(UnboundLocalError):
            a

    def test_del_in_loop(self):
        lst = list(range(5))
        while lst:
            del lst[-1]
        self.assertEqual(lst, [])


if __name__ == "__main__":
    unittest.main()
