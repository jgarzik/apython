"""Extra dict tests — adapted from CPython test_dict.py"""

import unittest


class DictTest(unittest.TestCase):

    def test_constructor(self):
        self.assertEqual(dict(), {})
        self.assertEqual(dict({}), {})

    def test_literal(self):
        d = {'a': 1, 'b': 2, 'c': 3}
        self.assertEqual(len(d), 3)
        self.assertEqual(d['a'], 1)

    def test_setitem_getitem(self):
        d = {}
        d['key'] = 'value'
        self.assertEqual(d['key'], 'value')
        d['key'] = 'new'
        self.assertEqual(d['key'], 'new')

    def test_delitem(self):
        d = {'a': 1, 'b': 2}
        del d['a']
        self.assertEqual(d, {'b': 2})
        with self.assertRaises(KeyError):
            del d['a']

    def test_contains(self):
        d = {'a': 1, 'b': 2}
        self.assertIn('a', d)
        self.assertNotIn('c', d)

    def test_len(self):
        self.assertEqual(len({}), 0)
        self.assertEqual(len({'a': 1}), 1)
        self.assertEqual(len({'a': 1, 'b': 2}), 2)

    def test_keys_values_items(self):
        d = {'a': 1, 'b': 2}
        self.assertEqual(sorted(d.keys()), ['a', 'b'])
        self.assertEqual(sorted(d.values()), [1, 2])
        self.assertEqual(sorted(d.items()), [('a', 1), ('b', 2)])

    def test_get(self):
        d = {'a': 1}
        self.assertEqual(d.get('a'), 1)
        self.assertIsNone(d.get('b'))
        self.assertEqual(d.get('b', 42), 42)

    def test_pop(self):
        d = {'a': 1, 'b': 2}
        self.assertEqual(d.pop('a'), 1)
        self.assertEqual(d, {'b': 2})
        self.assertEqual(d.pop('c', 99), 99)
        self.assertRaises(KeyError, d.pop, 'c')

    def test_update(self):
        d = {'a': 1}
        d.update({'b': 2, 'c': 3})
        self.assertEqual(d, {'a': 1, 'b': 2, 'c': 3})
        d.update({'a': 10})
        self.assertEqual(d['a'], 10)

    def test_setdefault(self):
        d = {'a': 1}
        self.assertEqual(d.setdefault('a', 99), 1)
        self.assertEqual(d.setdefault('b', 99), 99)
        self.assertEqual(d['b'], 99)

    def test_clear(self):
        d = {'a': 1, 'b': 2}
        d.clear()
        self.assertEqual(d, {})
        self.assertEqual(len(d), 0)

    def test_copy(self):
        d = {'a': 1, 'b': [2, 3]}
        d2 = d.copy()
        self.assertEqual(d, d2)
        d2['a'] = 99
        self.assertEqual(d['a'], 1)

    def test_iteration(self):
        d = {'a': 1, 'b': 2, 'c': 3}
        keys = []
        for k in d:
            keys.append(k)
        self.assertEqual(sorted(keys), ['a', 'b', 'c'])

    def test_comprehension(self):
        d = {x: x**2 for x in range(5)}
        self.assertEqual(len(d), 5)
        self.assertEqual(d[3], 9)
        self.assertEqual(d[4], 16)

    def test_equality(self):
        self.assertEqual({'a': 1}, {'a': 1})
        self.assertNotEqual({'a': 1}, {'a': 2})
        self.assertNotEqual({'a': 1}, {'b': 1})

    def test_bool(self):
        self.assertFalse(bool({}))
        self.assertTrue(bool({'a': 1}))

    def test_mixed_key_types(self):
        d = {1: 'int', 'a': 'str', (1, 2): 'tuple'}
        self.assertEqual(d[1], 'int')
        self.assertEqual(d['a'], 'str')
        self.assertEqual(d[(1, 2)], 'tuple')

    def test_fromkeys(self):
        d = dict.fromkeys(['a', 'b', 'c'], 0)
        self.assertEqual(len(d), 3)
        self.assertEqual(d['a'], 0)
        self.assertEqual(d['c'], 0)

    def test_nested(self):
        d = {'a': {'x': 1}, 'b': {'y': 2}}
        self.assertEqual(d['a']['x'], 1)
        self.assertEqual(d['b']['y'], 2)


if __name__ == "__main__":
    unittest.main()
