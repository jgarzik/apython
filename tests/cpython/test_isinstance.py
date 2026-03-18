"""CPython test_isinstance.py adapted for apython."""
import unittest


# Normal classes
class Super:
    pass

class Child(Super):
    pass


class TestIsInstanceIsSubclass(unittest.TestCase):

    def test_isinstance_normal(self):
        # normal instances
        self.assertEqual(True, isinstance(Super(), Super))
        self.assertEqual(False, isinstance(Super(), Child))

        self.assertEqual(True, isinstance(Child(), Super))
        self.assertEqual(True, isinstance(Child(), Child))

    def test_isinstance_builtin(self):
        self.assertTrue(isinstance(1, int))
        self.assertTrue(isinstance(1.0, float))
        self.assertTrue(isinstance("hello", str))
        self.assertTrue(isinstance([], list))
        self.assertTrue(isinstance({}, dict))
        self.assertTrue(isinstance((), tuple))
        self.assertTrue(isinstance(True, bool))
        self.assertTrue(isinstance(True, int))  # bool is subclass of int
        self.assertFalse(isinstance(1, str))
        self.assertFalse(isinstance("hello", int))

    def test_isinstance_tuple_arg(self):
        self.assertTrue(isinstance(1, (int, str)))
        self.assertTrue(isinstance("a", (int, str)))
        self.assertFalse(isinstance(1.0, (int, str)))

    def test_isinstance_none(self):
        self.assertFalse(isinstance(None, int))
        self.assertFalse(isinstance(None, str))
        self.assertFalse(isinstance(None, list))

    def test_subclass_normal(self):
        # normal classes
        self.assertEqual(True, issubclass(Super, Super))
        self.assertEqual(False, issubclass(Super, Child))

        self.assertEqual(True, issubclass(Child, Child))
        self.assertEqual(True, issubclass(Child, Super))

    def test_subclass_builtin(self):
        self.assertTrue(issubclass(bool, int))
        self.assertTrue(issubclass(int, int))
        self.assertFalse(issubclass(int, str))
        self.assertFalse(issubclass(str, int))

    def test_subclass_tuple(self):
        self.assertTrue(issubclass(bool, (int, str)))
        self.assertTrue(issubclass(str, (int, str)))
        self.assertFalse(issubclass(list, (int, str)))
        self.assertTrue(issubclass(Child, (Super, int)))
        self.assertFalse(issubclass(Super, (Child, str)))

    def test_isinstance_with_custom_class(self):
        class A:
            pass
        class B(A):
            pass
        class C(B):
            pass

        self.assertTrue(isinstance(C(), A))
        self.assertTrue(isinstance(C(), B))
        self.assertTrue(isinstance(C(), C))
        self.assertFalse(isinstance(A(), B))
        self.assertFalse(isinstance(A(), C))

    def test_issubclass_with_custom_class(self):
        class A:
            pass
        class B(A):
            pass
        class C(B):
            pass

        self.assertTrue(issubclass(C, A))
        self.assertTrue(issubclass(C, B))
        self.assertTrue(issubclass(C, C))
        self.assertTrue(issubclass(B, A))
        self.assertFalse(issubclass(A, B))
        self.assertFalse(issubclass(A, C))

    def test_isinstance_errors(self):
        self.assertRaises(TypeError, isinstance, 1, 1)
        self.assertRaises(TypeError, isinstance, 1, "not_a_type")

    def test_issubclass_errors(self):
        self.assertRaises(TypeError, issubclass, 1, int)
        self.assertRaises(TypeError, issubclass, int, 1)
        self.assertRaises(TypeError, issubclass, 1, 1)


if __name__ == "__main__":
    unittest.main()
