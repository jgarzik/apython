"""Tests for property descriptors — adapted from CPython test_property.py"""

import unittest


class PropertyTest(unittest.TestCase):

    def test_basic_property(self):
        class C:
            def __init__(self):
                self._x = 0
            @property
            def x(self):
                return self._x
            @x.setter
            def x(self, value):
                self._x = value
        obj = C()
        self.assertEqual(obj.x, 0)
        obj.x = 42
        self.assertEqual(obj.x, 42)

    def test_readonly_property(self):
        class C:
            @property
            def x(self):
                return 42
        obj = C()
        self.assertEqual(obj.x, 42)

    @unittest.skip("property deleter not implemented")
    def test_property_with_delete(self):
        pass

    def test_computed_property(self):
        class Circle:
            def __init__(self, radius):
                self.radius = radius
            @property
            def area(self):
                return 3.14159 * self.radius ** 2
        c = Circle(10)
        self.assertAlmostEqual(c.area, 314.159)

    def test_property_inheritance(self):
        class Base:
            @property
            def x(self):
                return 1
        class Child(Base):
            pass
        self.assertEqual(Child().x, 1)

    def test_property_old_style(self):
        class C:
            def getx(self):
                return self._x
            def setx(self, val):
                self._x = val
            x = property(getx, setx)
        obj = C()
        obj.x = 99
        self.assertEqual(obj.x, 99)


class StaticMethodTest(unittest.TestCase):

    def test_basic(self):
        class C:
            @staticmethod
            def f(x):
                return x + 1
        self.assertEqual(C.f(5), 6)
        self.assertEqual(C().f(5), 6)

    def test_with_args(self):
        class C:
            @staticmethod
            def add(a, b):
                return a + b
        self.assertEqual(C.add(3, 4), 7)


class ClassMethodTest(unittest.TestCase):

    def test_basic(self):
        class C:
            val = 10
            @classmethod
            def f(cls):
                return cls.val
        self.assertEqual(C.f(), 10)
        self.assertEqual(C().f(), 10)

    def test_inheritance(self):
        class Base:
            val = 1
            @classmethod
            def f(cls):
                return cls.val
        class Child(Base):
            val = 2
        self.assertEqual(Base.f(), 1)
        self.assertEqual(Child.f(), 2)


if __name__ == "__main__":
    unittest.main()
