"""Tests for data structure operations — mixed-type scenarios"""

import unittest


class NestedStructTest(unittest.TestCase):

    def test_list_of_dicts(self):
        data = [{"name": "a", "val": 1}, {"name": "b", "val": 2}]
        self.assertEqual(data[0]["name"], "a")
        self.assertEqual(data[1]["val"], 2)

    def test_dict_of_lists(self):
        d = {"evens": [0, 2, 4], "odds": [1, 3, 5]}
        self.assertEqual(d["evens"][1], 2)
        self.assertEqual(d["odds"][2], 5)

    def test_nested_list(self):
        matrix = [[1, 2, 3], [4, 5, 6], [7, 8, 9]]
        flat = [x for row in matrix for x in row]
        self.assertEqual(flat, [1, 2, 3, 4, 5, 6, 7, 8, 9])

    def test_list_of_tuples(self):
        pairs = [(1, 'a'), (2, 'b'), (3, 'c')]
        keys = [k for k, v in pairs]
        vals = [v for k, v in pairs]
        self.assertEqual(keys, [1, 2, 3])
        self.assertEqual(vals, ['a', 'b', 'c'])

    def test_dict_from_zip(self):
        keys = ['a', 'b', 'c']
        vals = [1, 2, 3]
        d = {}
        for k, v in zip(keys, vals):
            d[k] = v
        self.assertEqual(d['b'], 2)

    def test_set_from_list(self):
        data = [1, 2, 2, 3, 3, 3]
        unique = sorted(list(set(data)))
        self.assertEqual(unique, [1, 2, 3])

    def test_stack(self):
        stack = []
        stack.append(1)
        stack.append(2)
        stack.append(3)
        self.assertEqual(stack.pop(), 3)
        self.assertEqual(stack.pop(), 2)
        self.assertEqual(len(stack), 1)

    def test_queue_via_list(self):
        q = []
        q.append("first")
        q.append("second")
        q.append("third")
        self.assertEqual(q.pop(0), "first")
        self.assertEqual(q.pop(0), "second")

    def test_frequency_count(self):
        text = "abracadabra"
        freq = {}
        for ch in text:
            freq[ch] = freq.get(ch, 0) + 1
        self.assertEqual(freq['a'], 5)
        self.assertEqual(freq['b'], 2)

    def test_groupby_manual(self):
        data = [("a", 1), ("b", 2), ("a", 3), ("b", 4)]
        groups = {}
        for key, val in data:
            if key not in groups:
                groups[key] = []
            groups[key].append(val)
        self.assertEqual(groups["a"], [1, 3])
        self.assertEqual(groups["b"], [2, 4])


class SortingTest(unittest.TestCase):

    def test_sort_key(self):
        data = ["banana", "apple", "cherry"]
        data.sort(key=len)
        self.assertEqual(data, ["apple", "banana", "cherry"])

    def test_sorted_key(self):
        data = [(3, "c"), (1, "a"), (2, "b")]
        result = sorted(data, key=lambda x: x[0])
        self.assertEqual(result, [(1, "a"), (2, "b"), (3, "c")])

    def test_reverse_sort(self):
        data = [3, 1, 4, 1, 5]
        self.assertEqual(sorted(data, reverse=True), [5, 4, 3, 1, 1])

    def test_stable_sort(self):
        data = [(1, 'b'), (2, 'a'), (1, 'a'), (2, 'b')]
        result = sorted(data, key=lambda x: x[0])
        self.assertEqual(result[0], (1, 'b'))
        self.assertEqual(result[1], (1, 'a'))


if __name__ == "__main__":
    unittest.main()
