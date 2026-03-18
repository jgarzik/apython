"""Tests for with statement — adapted from CPython test_with.py"""

import unittest


class WithBasicTest(unittest.TestCase):

    def test_basic(self):
        class CM:
            def __init__(self):
                self.entered = False
                self.exited = False
            def __enter__(self):
                self.entered = True
                return self
            def __exit__(self, *args):
                self.exited = True
                return False
        cm = CM()
        with cm:
            self.assertTrue(cm.entered)
            self.assertFalse(cm.exited)
        self.assertTrue(cm.exited)

    def test_as_clause(self):
        class CM:
            def __enter__(self):
                return 42
            def __exit__(self, *args):
                return False
        with CM() as val:
            self.assertEqual(val, 42)

    def test_exception_in_body(self):
        class CM:
            def __init__(self):
                self.exit_args = None
            def __enter__(self):
                return self
            def __exit__(self, *args):
                self.exit_args = args
                return False
        cm = CM()
        try:
            with cm:
                raise ValueError("test")
        except ValueError:
            pass
        self.assertEqual(cm.exit_args[0], ValueError)

    def test_suppress_exception(self):
        class CM:
            def __enter__(self):
                return self
            def __exit__(self, *args):
                return True  # suppress
        with CM():
            raise ValueError("suppressed")
        # Should reach here without error

    def test_name_error(self):
        def f():
            with undefined_var:
                pass
        self.assertRaises(NameError, f)

    def test_enter_attr_error(self):
        class NoEnter:
            def __exit__(self, *args):
                pass
        def f():
            with NoEnter():
                pass
        self.assertRaises(AttributeError, f)

    def test_nested_with(self):
        order = []
        class CM:
            def __init__(self, name):
                self.name = name
            def __enter__(self):
                order.append('enter_' + self.name)
                return self
            def __exit__(self, *args):
                order.append('exit_' + self.name)
                return False
        with CM('a'):
            with CM('b'):
                order.append('body')
        self.assertEqual(order,
                         ['enter_a', 'enter_b', 'body', 'exit_b', 'exit_a'])

    def test_exception_in_exit(self):
        class CM:
            def __enter__(self):
                return self
            def __exit__(self, *args):
                raise TypeError("in exit")
        try:
            with CM():
                pass
        except TypeError as e:
            self.assertEqual(str(e), "in exit")
        else:
            self.fail("TypeError not raised")

    def test_finally_semantics(self):
        # With should behave like try/finally for cleanup
        cleanup = []
        class CM:
            def __enter__(self):
                return self
            def __exit__(self, *args):
                cleanup.append('cleanup')
                return False
        try:
            with CM():
                cleanup.append('body')
                raise ValueError("test")
        except ValueError:
            pass
        self.assertEqual(cleanup, ['body', 'cleanup'])

    def test_return_in_with(self):
        class CM:
            def __init__(self):
                self.exited = False
            def __enter__(self):
                return self
            def __exit__(self, *args):
                self.exited = True
                return False
        cm = CM()
        def f():
            with cm:
                return 42
        self.assertEqual(f(), 42)
        self.assertTrue(cm.exited)

    def test_break_in_with(self):
        class CM:
            def __init__(self):
                self.exit_count = 0
            def __enter__(self):
                return self
            def __exit__(self, *args):
                self.exit_count += 1
                return False
        cm = CM()
        for i in range(3):
            with cm:
                if i == 1:
                    break
        self.assertEqual(cm.exit_count, 2)  # entered twice (i=0 and i=1)

    def test_continue_in_with(self):
        class CM:
            def __init__(self):
                self.exit_count = 0
            def __enter__(self):
                return self
            def __exit__(self, *args):
                self.exit_count += 1
                return False
        cm = CM()
        for i in range(3):
            with cm:
                continue
        self.assertEqual(cm.exit_count, 3)


if __name__ == "__main__":
    unittest.main()
