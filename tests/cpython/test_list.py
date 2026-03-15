"""CPython test_list.py adapted for apython."""
import sys
from test import list_tests
import unittest

def cpython_only(func):
    return unittest.skip("CPython only")(func)

class ListTest(list_tests.CommonTest):
    type2test = list

    def test_basic(self):
        self.assertEqual(list([]), [])
        l0_3 = [0, 1, 2, 3]
        l0_3_bis = list(l0_3)
        self.assertEqual(l0_3, l0_3_bis)
        self.assertTrue(l0_3 is not l0_3_bis)
        self.assertEqual(list(()), [])
        self.assertEqual(list((0, 1, 2, 3)), [0, 1, 2, 3])
        self.assertEqual(list(''), [])
        self.assertEqual(list('spam'), ['s', 'p', 'a', 'm'])
        self.assertEqual(list(x for x in range(10) if x % 2),
                         [1, 3, 5, 7, 9])

        # This code used to segfault in Py2.4a3
        x = []
        x.extend(-y for y in x)
        self.assertEqual(x, [])

    def test_keyword_args(self):
        with self.assertRaisesRegex(TypeError, 'keyword argument'):
            list(sequence=[])

    def test_keywords_in_subclass(self):
        class subclass(list):
            pass
        u = subclass([1, 2])
        self.assertIs(type(u), subclass)
        self.assertEqual(list(u), [1, 2])
        with self.assertRaises(TypeError):
            subclass(sequence=())

        class subclass_with_init(list):
            def __init__(self, seq, newarg=None):
                super().__init__(seq)
                self.newarg = newarg
        u = subclass_with_init([1, 2], newarg=3)
        self.assertIs(type(u), subclass_with_init)
        self.assertEqual(list(u), [1, 2])
        self.assertEqual(u.newarg, 3)

        class subclass_with_new(list):
            def __new__(cls, seq, newarg=None):
                self = super().__new__(cls, seq)
                self.newarg = newarg
                return self
        u = subclass_with_new([1, 2], newarg=3)
        self.assertIs(type(u), subclass_with_new)
        self.assertEqual(list(u), [1, 2])
        self.assertEqual(u.newarg, 3)

    def test_truth(self):
        super().test_truth()
        self.assertTrue(not [])
        self.assertTrue([42])

    def test_identity(self):
        self.assertTrue([] is not [])

    def test_len(self):
        super().test_len()
        self.assertEqual(len([]), 0)
        self.assertEqual(len([0]), 1)
        self.assertEqual(len([0, 1, 2]), 3)

    def test_overflow(self):
        lst = [4, 5, 6, 7]
        n = int((sys.maxsize*2+2) // len(lst))
        def mul(a, b): return a * b
        def imul(a, b): a *= b
        self.assertRaises((MemoryError, OverflowError), mul, lst, n)
        self.assertRaises((MemoryError, OverflowError), imul, lst, n)

    def test_list_resize_overflow(self):
        # gh-97616: test new_allocated * sizeof(PyObject*) overflow
        # check in list_resize()
        lst = [0] * 65
        del lst[1:]
        self.assertEqual(len(lst), 1)

        size = sys.maxsize
        with self.assertRaises((MemoryError, OverflowError)):
            lst * size
        with self.assertRaises((MemoryError, OverflowError)):
            lst *= size

    def test_repr_large(self):
        # Check the repr of large list objects
        def check(n):
            l = [0] * n
            s = repr(l)
            self.assertEqual(s,
                '[' + ', '.join(['0'] * n) + ']')
        check(10)       # check our checking code
        check(1000000)

    @unittest.skip("not implemented")
    def test_iterator_serialization(self):
        pass

    @unittest.skip("not implemented")
    def test_reversed_serialization(self):
        pass

    def test_step_overflow(self):
        a = [0, 1, 2, 3, 4]
        a[1::sys.maxsize] = [0]
        self.assertEqual(a[3::sys.maxsize], [3])

    def test_no_comdat_folding(self):
        # Issue 8847: In the PGO build, the MSVC linker's COMDAT folding
        # optimization causes failures in code that relies on distinct
        # function addresses.
        class L(list): pass
        with self.assertRaises(TypeError):
            (3,) + L([1,2])

    def test_equal_operator_modifying_operand(self):
        # test fix for seg fault reported in bpo-38588 part 2.
        class X:
            def __eq__(self,other) :
                list2.clear()
                return NotImplemented

        class Y:
            def __eq__(self, other):
                list1.clear()
                return NotImplemented

        class Z:
            def __eq__(self, other):
                list3.clear()
                return NotImplemented

        list1 = [X()]
        list2 = [Y()]
        self.assertTrue(list1 == list2)

        list3 = [Z()]
        list4 = [1]
        self.assertFalse(list3 == list4)

    @cpython_only
    def test_preallocation(self):
        pass

    def test_count_index_remove_crashes(self):
        # bpo-38610: The count(), index(), and remove() methods were not
        # holding strong references to list elements while calling
        # PyObject_RichCompareBool().
        class X:
            def __eq__(self, other):
                lst.clear()
                return NotImplemented

        lst = [X()]
        with self.assertRaises(ValueError):
            lst.index(lst)

        class L(list):
            def __eq__(self, other):
                str(other)
                return NotImplemented

        lst = L([X()])
        lst.count(lst)

        lst = L([X()])
        with self.assertRaises(ValueError):
            lst.remove(lst)

        # bpo-39453: list.__contains__ was not holding strong references
        # to list elements while calling PyObject_RichCompareBool().
        lst = [X(), X()]
        3 in lst
        lst = [X(), X()]
        X() in lst


if __name__ == "__main__":
    unittest.main()
