"""CPython test_dict.py adapted for apython."""
import sys
import unittest

class DictTest(unittest.TestCase):

    def test_constructor(self):
        self.assertEqual(dict(), {})

    def test_bool(self):
        self.assertIs(not {}, True)
        self.assertTrue({1: 2})
        self.assertIs(bool({}), False)
        self.assertIs(bool({1: 2}), True)

    def test_keys(self):
        d = {}
        self.assertEqual(sorted(d.keys()), [])
        d = {'a': 1, 'b': 2}
        k = d.keys()
        self.assertEqual(sorted(k), ['a', 'b'])
        self.assertIn('a', k)
        self.assertIn('b', k)
        self.assertIn('a', d)
        self.assertIn('b', d)

    def test_values(self):
        d = {}
        self.assertEqual(sorted(d.values()), [])
        d = {1: 2}
        self.assertEqual(sorted(d.values()), [2])

    def test_items(self):
        d = {}
        self.assertEqual(sorted(d.items()), [])
        d = {1: 2}
        self.assertEqual(sorted(d.items()), [(1, 2)])

    def test_contains(self):
        d = {}
        self.assertNotIn('a', d)
        self.assertTrue(not ('a' in d))
        self.assertTrue('a' not in d)
        d = {'a': 1, 'b': 2}
        self.assertIn('a', d)
        self.assertIn('b', d)
        self.assertNotIn('c', d)

    def test_len(self):
        d = {}
        self.assertEqual(len(d), 0)
        d = {'a': 1, 'b': 2}
        self.assertEqual(len(d), 2)

    def test_getitem(self):
        d = {'a': 1, 'b': 2}
        self.assertEqual(d['a'], 1)
        self.assertEqual(d['b'], 2)
        try:
            d['c']
            self.fail("Expected KeyError")
        except KeyError:
            pass

        d = {1: 'a', 2: 'b'}
        self.assertEqual(d[1], 'a')
        self.assertEqual(d[2], 'b')

    def test_clear(self):
        d = {1: 1, 2: 2, 3: 3}
        d.clear()
        self.assertEqual(d, {})

    def test_update(self):
        d = {}
        d.update({1: 100})
        d.update({2: 20})
        d.update({1: 1, 2: 2, 3: 3})
        self.assertEqual(d, {1: 1, 2: 2, 3: 3})

        d.update()
        self.assertEqual(d, {1: 1, 2: 2, 3: 3})

    def test_fromkeys(self):
        d = dict.fromkeys([1, 2, 3])
        self.assertEqual(d, {1: None, 2: None, 3: None})
        d = dict.fromkeys([1, 2, 3], 'x')
        self.assertEqual(d, {1: 'x', 2: 'x', 3: 'x'})
        d = dict.fromkeys([])
        self.assertEqual(d, {})

    def test_copy(self):
        d = {1: 1, 2: 2, 3: 3}
        self.assertEqual(d.copy(), {1: 1, 2: 2, 3: 3})
        self.assertEqual({}.copy(), {})

        # Verify it's a shallow copy
        d = {1: [1]}
        e = d.copy()
        self.assertEqual(e, {1: [1]})
        self.assertIs(d[1], e[1])

    def test_get(self):
        d = {}
        self.assertIs(d.get('c'), None)
        self.assertEqual(d.get('c', 3), 3)
        d = {'a': 1, 'b': 2}
        self.assertIs(d.get('c'), None)
        self.assertEqual(d.get('c', 3), 3)
        self.assertEqual(d.get('a'), 1)
        self.assertEqual(d.get('a', 3), 1)

    def test_setdefault(self):
        d = {}
        self.assertIs(d.setdefault('key0'), None)
        d.setdefault('key0', [])
        self.assertIs(d.setdefault('key0'), None)
        d.setdefault('key', []).append(3)
        self.assertEqual(d['key'][0], 3)
        d.setdefault('key', []).append(4)
        self.assertEqual(len(d['key']), 2)

    def test_pop(self):
        d = {}
        try:
            d.pop('abc')
            self.fail("Expected KeyError")
        except KeyError:
            pass
        d = {'abc': 'def'}
        self.assertEqual(d.pop('abc'), 'def')
        self.assertEqual(len(d), 0)
        d = {'abc': 'def'}
        self.assertEqual(d.pop('abc', 'ghi'), 'def')
        self.assertEqual(d.pop('abc', 'ghi'), 'ghi')
        self.assertEqual(len(d), 0)

    def test_popitem(self):
        d = {1: 'a', 2: 'b', 3: 'c'}
        items = []
        while d:
            items.append(d.popitem())
        self.assertEqual(len(items), 3)
        self.assertEqual(sorted(items), [(1, 'a'), (2, 'b'), (3, 'c')])
        try:
            d.popitem()
            self.fail("Expected KeyError")
        except KeyError:
            pass

    def test_repr(self):
        d = {}
        self.assertEqual(repr(d), '{}')
        d = {1: 2}
        self.assertEqual(repr(d), '{1: 2}')

    def test_eq(self):
        self.assertEqual({}, {})
        self.assertEqual({1: 2}, {1: 2})
        self.assertNotEqual({1: 2}, {1: 3})
        self.assertNotEqual({1: 2}, {2: 2})

    def test_resize(self):
        d = {}
        for i in range(100):
            d[i] = i
        self.assertEqual(len(d), 100)
        for i in range(100):
            self.assertEqual(d[i], i)

    def test_delete(self):
        d = {1: 'a', 2: 'b', 3: 'c'}
        del d[2]
        self.assertEqual(d, {1: 'a', 3: 'c'})
        try:
            del d[4]
            self.fail("Expected KeyError")
        except KeyError:
            pass

    def test_iteration(self):
        d = {1: 'a', 2: 'b', 3: 'c'}
        keys = []
        for k in d:
            keys.append(k)
        self.assertEqual(sorted(keys), [1, 2, 3])

        values = []
        for v in d.values():
            values.append(v)
        self.assertEqual(sorted(values), ['a', 'b', 'c'])

        items = []
        for k, v in d.items():
            items.append((k, v))
        self.assertEqual(sorted(items), [(1, 'a'), (2, 'b'), (3, 'c')])

    def test_dict_comprehension(self):
        d = {k: v for k, v in [('a', 1), ('b', 2)]}
        self.assertEqual(d, {'a': 1, 'b': 2})

        d = {i: i*i for i in range(5)}
        self.assertEqual(d, {0: 0, 1: 1, 2: 4, 3: 9, 4: 16})

    def test_mixed_keys(self):
        d = {1: 'int', 'a': 'str', (1, 2): 'tuple'}
        self.assertEqual(d[1], 'int')
        self.assertEqual(d['a'], 'str')
        self.assertEqual(d[(1, 2)], 'tuple')

    def test_empty_dict_equality(self):
        self.assertEqual({}, {})
        self.assertNotEqual({}, {1: 2})
        self.assertNotEqual({1: 2}, {})

    def test_large_dict(self):
        d = {}
        for i in range(1000):
            d[str(i)] = i
        self.assertEqual(len(d), 1000)
        for i in range(1000):
            self.assertEqual(d[str(i)], i)


if __name__ == "__main__":
    unittest.main()
