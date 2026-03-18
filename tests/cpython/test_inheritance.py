"""Tests for inheritance and method resolution"""

import unittest


class BasicInheritanceTest(unittest.TestCase):

    def test_single_inheritance(self):
        class Animal:
            def speak(self):
                return "..."
        class Dog(Animal):
            def speak(self):
                return "woof"
        class Cat(Animal):
            def speak(self):
                return "meow"
        self.assertEqual(Dog().speak(), "woof")
        self.assertEqual(Cat().speak(), "meow")

    def test_inherit_method(self):
        class Base:
            def greet(self):
                return "hello"
        class Child(Base):
            pass
        self.assertEqual(Child().greet(), "hello")

    def test_inherit_attribute(self):
        class Base:
            x = 10
        class Child(Base):
            pass
        self.assertEqual(Child.x, 10)
        self.assertEqual(Child().x, 10)

    def test_override(self):
        class Base:
            def f(self):
                return 1
        class Child(Base):
            def f(self):
                return 2
        self.assertEqual(Base().f(), 1)
        self.assertEqual(Child().f(), 2)

    def test_super(self):
        class Base:
            def __init__(self):
                self.base_init = True
        class Child(Base):
            def __init__(self):
                super().__init__()
                self.child_init = True
        obj = Child()
        self.assertTrue(obj.base_init)
        self.assertTrue(obj.child_init)

    def test_super_method(self):
        class Base:
            def f(self):
                return "base"
        class Child(Base):
            def f(self):
                return super().f() + "_child"
        self.assertEqual(Child().f(), "base_child")

    def test_three_levels(self):
        class A:
            def f(self):
                return "A"
        class B(A):
            def f(self):
                return super().f() + "B"
        class C(B):
            def f(self):
                return super().f() + "C"
        self.assertEqual(C().f(), "ABC")

    def test_isinstance_chain(self):
        class A: pass
        class B(A): pass
        class C(B): pass
        c = C()
        self.assertTrue(isinstance(c, C))
        self.assertTrue(isinstance(c, B))
        self.assertTrue(isinstance(c, A))
        self.assertFalse(isinstance(A(), C))

    def test_issubclass_chain(self):
        class A: pass
        class B(A): pass
        class C(B): pass
        self.assertTrue(issubclass(C, A))
        self.assertTrue(issubclass(C, B))
        self.assertTrue(issubclass(B, A))
        self.assertFalse(issubclass(A, B))

    def test_class_attribute_override(self):
        class Base:
            x = 1
        class Child(Base):
            x = 2
        class GrandChild(Child):
            pass
        self.assertEqual(Base.x, 1)
        self.assertEqual(Child.x, 2)
        self.assertEqual(GrandChild.x, 2)


class ExceptionInheritanceTest(unittest.TestCase):

    def test_custom_exception(self):
        class AppError(Exception):
            pass
        class DatabaseError(AppError):
            pass
        try:
            raise DatabaseError("db down")
        except AppError as e:
            self.assertEqual(str(e), "db down")
        else:
            self.fail("AppError didn't catch DatabaseError")

    def test_exception_hierarchy(self):
        class MyError(ValueError):
            pass
        self.assertTrue(issubclass(MyError, ValueError))
        self.assertTrue(issubclass(MyError, Exception))

    def test_catch_parent(self):
        class Specific(RuntimeError):
            pass
        caught = False
        try:
            raise Specific()
        except RuntimeError:
            caught = True
        self.assertTrue(caught)


if __name__ == "__main__":
    unittest.main()
