"""Tests for class features — adapted from CPython test_class.py"""

import unittest


class ClassBasicTest(unittest.TestCase):

    def test_class_creation(self):
        class C:
            pass
        self.assertTrue(isinstance(C(), C))

    def test_class_with_init(self):
        class C:
            def __init__(self, x):
                self.x = x
        obj = C(42)
        self.assertEqual(obj.x, 42)

    def test_inheritance(self):
        class Base:
            def method(self):
                return "base"
        class Child(Base):
            pass
        self.assertEqual(Child().method(), "base")

    def test_method_override(self):
        class Base:
            def method(self):
                return "base"
        class Child(Base):
            def method(self):
                return "child"
        self.assertEqual(Child().method(), "child")

    def test_isinstance_inheritance(self):
        class A:
            pass
        class B(A):
            pass
        class C(B):
            pass
        obj = C()
        self.assertTrue(isinstance(obj, C))
        self.assertTrue(isinstance(obj, B))
        self.assertTrue(isinstance(obj, A))

    def test_class_attributes(self):
        class C:
            x = 42
            def get_x(self):
                return self.x
        self.assertEqual(C.x, 42)
        self.assertEqual(C().get_x(), 42)

    def test_instance_attributes(self):
        class C:
            def __init__(self):
                self.x = 1
                self.y = 2
        obj = C()
        self.assertEqual(obj.x, 1)
        self.assertEqual(obj.y, 2)
        obj.x = 10
        self.assertEqual(obj.x, 10)

    def test_class_dict(self):
        class C:
            x = 1
            y = 2
        self.assertEqual(C.x, 1)
        self.assertEqual(C.y, 2)


class ClassDunderTest(unittest.TestCase):

    def test_repr(self):
        class C:
            def __repr__(self):
                return "C()"
        self.assertEqual(repr(C()), "C()")

    def test_str(self):
        class C:
            def __str__(self):
                return "hello"
        self.assertEqual(str(C()), "hello")

    def test_len(self):
        class C:
            def __len__(self):
                return 42
        self.assertEqual(len(C()), 42)

    def test_bool(self):
        class Falsy:
            def __bool__(self):
                return False
        class Truthy:
            def __bool__(self):
                return True
        self.assertFalse(bool(Falsy()))
        self.assertTrue(bool(Truthy()))

    def test_eq(self):
        class C:
            def __init__(self, x):
                self.x = x
            def __eq__(self, other):
                return self.x == other.x
            def __ne__(self, other):
                return self.x != other.x
        self.assertEqual(C(1), C(1))
        self.assertNotEqual(C(1), C(2))
        self.assertTrue(C(1) == C(1))
        self.assertFalse(C(1) == C(2))
        self.assertFalse(C(1) != C(1))
        self.assertTrue(C(1) != C(2))

    def test_lt_gt(self):
        class C:
            def __init__(self, x):
                self.x = x
            def __lt__(self, other):
                return self.x < other.x
            def __gt__(self, other):
                return self.x > other.x
        self.assertTrue(C(1) < C(2))
        self.assertFalse(C(2) < C(1))
        self.assertTrue(C(2) > C(1))

    def test_add(self):
        class C:
            def __init__(self, x):
                self.x = x
            def __add__(self, other):
                return C(self.x + other.x)
        result = C(1) + C(2)
        self.assertEqual(result.x, 3)

    def test_getitem(self):
        class C:
            def __getitem__(self, key):
                return key * 2
        self.assertEqual(C()[3], 6)
        self.assertEqual(C()["ab"], "abab")

    def test_setitem(self):
        class C:
            def __init__(self):
                self.data = {}
            def __setitem__(self, key, value):
                self.data[key] = value
        obj = C()
        obj[1] = "one"
        self.assertEqual(obj.data[1], "one")

    def test_contains(self):
        class C:
            def __contains__(self, item):
                return item == 42
        self.assertTrue(42 in C())
        self.assertFalse(0 in C())

    def test_iter(self):
        class C:
            def __iter__(self):
                return iter([1, 2, 3])
        self.assertEqual(list(C()), [1, 2, 3])

    def test_call(self):
        class C:
            def __call__(self, x):
                return x + 1
        self.assertEqual(C()(5), 6)


class ClassInheritanceTest(unittest.TestCase):

    def test_super_init(self):
        class Base:
            def __init__(self):
                self.base_val = 1
        class Child(Base):
            def __init__(self):
                super().__init__()
                self.child_val = 2
        obj = Child()
        self.assertEqual(obj.base_val, 1)
        self.assertEqual(obj.child_val, 2)

    def test_multiple_levels(self):
        class A:
            def who(self):
                return 'A'
        class B(A):
            pass
        class C(B):
            pass
        self.assertEqual(C().who(), 'A')

    def test_override_chain(self):
        class A:
            def f(self):
                return 1
        class B(A):
            def f(self):
                return 2
        class C(B):
            def f(self):
                return 3
        self.assertEqual(A().f(), 1)
        self.assertEqual(B().f(), 2)
        self.assertEqual(C().f(), 3)

    def test_issubclass(self):
        class A:
            pass
        class B(A):
            pass
        class C(B):
            pass
        self.assertTrue(issubclass(C, A))
        self.assertTrue(issubclass(C, B))
        self.assertTrue(issubclass(B, A))
        self.assertFalse(issubclass(A, B))


if __name__ == "__main__":
    unittest.main()
