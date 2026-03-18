"""Tests for iterator protocol — adapted from CPython test_iter.py"""

import unittest


class BasicIterTest(unittest.TestCase):

    def test_iter_list(self):
        self.assertEqual(list(iter([1, 2, 3])), [1, 2, 3])

    def test_iter_tuple(self):
        self.assertEqual(list(iter((1, 2, 3))), [1, 2, 3])

    def test_iter_string(self):
        self.assertEqual(list(iter("abc")), ['a', 'b', 'c'])

    def test_iter_range(self):
        self.assertEqual(list(iter(range(5))), [0, 1, 2, 3, 4])

    def test_iter_dict_keys(self):
        d = {'a': 1, 'b': 2, 'c': 3}
        keys = list(iter(d))
        self.assertEqual(sorted(keys), ['a', 'b', 'c'])

    def test_next_with_default(self):
        it = iter([1])
        self.assertEqual(next(it), 1)
        self.assertEqual(next(it, 'default'), 'default')

    def test_stopiteration(self):
        it = iter([])
        self.assertRaises(StopIteration, next, it)

    def test_for_loop(self):
        result = []
        for x in [1, 2, 3]:
            result.append(x)
        self.assertEqual(result, [1, 2, 3])

    def test_for_loop_break(self):
        result = []
        for x in range(10):
            if x == 5:
                break
            result.append(x)
        self.assertEqual(result, [0, 1, 2, 3, 4])

    def test_for_loop_continue(self):
        result = []
        for x in range(10):
            if x % 2 == 0:
                continue
            result.append(x)
        self.assertEqual(result, [1, 3, 5, 7, 9])

    def test_for_else(self):
        hit_else = False
        for x in range(3):
            pass
        else:
            hit_else = True
        self.assertTrue(hit_else)

    def test_for_else_break(self):
        hit_else = False
        for x in range(3):
            break
        else:
            hit_else = True
        self.assertFalse(hit_else)

    def test_nested_for(self):
        result = []
        for x in range(3):
            for y in range(3):
                result.append((x, y))
        self.assertEqual(len(result), 9)
        self.assertEqual(result[0], (0, 0))
        self.assertEqual(result[-1], (2, 2))

    def test_enumerate(self):
        self.assertEqual(list(enumerate('abc')),
                         [(0, 'a'), (1, 'b'), (2, 'c')])
        self.assertEqual(list(enumerate('abc', 1)),
                         [(1, 'a'), (2, 'b'), (3, 'c')])

    def test_zip(self):
        self.assertEqual(list(zip([1, 2], [3, 4])),
                         [(1, 3), (2, 4)])
        self.assertEqual(list(zip([1, 2, 3], [4, 5])),
                         [(1, 4), (2, 5)])

    def test_map(self):
        def double(x):
            return x * 2
        self.assertEqual(list(map(double, [1, 2, 3])), [2, 4, 6])

    def test_filter(self):
        def is_even(x):
            return x % 2 == 0
        self.assertEqual(list(filter(is_even, range(10))),
                         [0, 2, 4, 6, 8])

    def test_reversed(self):
        self.assertEqual(list(reversed([1, 2, 3])), [3, 2, 1])
        self.assertEqual(list(reversed(range(5))), [4, 3, 2, 1, 0])

    def test_sorted(self):
        self.assertEqual(sorted([3, 1, 2]), [1, 2, 3])
        self.assertEqual(sorted([3, 1, 2], reverse=True), [3, 2, 1])

    def test_sum(self):
        self.assertEqual(sum([1, 2, 3]), 6)
        self.assertEqual(sum(range(10)), 45)
        self.assertEqual(sum([], 10), 10)

    def test_min_max(self):
        self.assertEqual(min([3, 1, 2]), 1)
        self.assertEqual(max([3, 1, 2]), 3)
        self.assertEqual(min(3, 1, 2), 1)
        self.assertEqual(max(3, 1, 2), 3)

    def test_any_all(self):
        self.assertTrue(any([0, 0, 1]))
        self.assertFalse(any([0, 0, 0]))
        self.assertTrue(all([1, 1, 1]))
        self.assertFalse(all([1, 0, 1]))
        self.assertTrue(any(x > 3 for x in range(5)))
        self.assertTrue(all(x < 5 for x in range(5)))


class CustomIterTest(unittest.TestCase):

    def test_iter_protocol(self):
        class MyIter:
            def __init__(self, data):
                self.data = data
                self.idx = 0
            def __iter__(self):
                return self
            def __next__(self):
                if self.idx >= len(self.data):
                    raise StopIteration
                val = self.data[self.idx]
                self.idx += 1
                return val
        self.assertEqual(list(MyIter([10, 20, 30])), [10, 20, 30])

    def test_getitem_protocol(self):
        class MySeq:
            def __init__(self, data):
                self.data = data
            def __getitem__(self, idx):
                return self.data[idx]
        self.assertEqual(list(MySeq([1, 2, 3])), [1, 2, 3])

    def test_iter_in_for(self):
        class Counter:
            def __init__(self, n):
                self.n = n
                self.i = 0
            def __iter__(self):
                return self
            def __next__(self):
                if self.i >= self.n:
                    raise StopIteration
                self.i += 1
                return self.i
        self.assertEqual(list(Counter(5)), [1, 2, 3, 4, 5])


if __name__ == "__main__":
    unittest.main()
