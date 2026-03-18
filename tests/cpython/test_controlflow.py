"""Tests for control flow — if/elif/else, while, for, break, continue, pass"""

import unittest


class IfTest(unittest.TestCase):

    def test_basic_if(self):
        x = 10
        if x > 5:
            result = "big"
        else:
            result = "small"
        self.assertEqual(result, "big")

    def test_elif(self):
        def classify(x):
            if x < 0:
                return "negative"
            elif x == 0:
                return "zero"
            elif x < 10:
                return "small"
            else:
                return "big"
        self.assertEqual(classify(-5), "negative")
        self.assertEqual(classify(0), "zero")
        self.assertEqual(classify(5), "small")
        self.assertEqual(classify(100), "big")

    def test_nested_if(self):
        def f(x, y):
            if x > 0:
                if y > 0:
                    return "both positive"
                else:
                    return "x positive"
            else:
                return "x not positive"
        self.assertEqual(f(1, 1), "both positive")
        self.assertEqual(f(1, -1), "x positive")
        self.assertEqual(f(-1, 1), "x not positive")

    def test_ternary(self):
        self.assertEqual("yes" if True else "no", "yes")
        self.assertEqual("yes" if False else "no", "no")
        x = 10
        self.assertEqual("big" if x > 5 else "small", "big")


class WhileTest(unittest.TestCase):

    def test_basic_while(self):
        n = 0
        while n < 10:
            n += 1
        self.assertEqual(n, 10)

    def test_while_break(self):
        n = 0
        while True:
            n += 1
            if n == 5:
                break
        self.assertEqual(n, 5)

    def test_while_continue(self):
        result = []
        n = 0
        while n < 10:
            n += 1
            if n % 2 == 0:
                continue
            result.append(n)
        self.assertEqual(result, [1, 3, 5, 7, 9])

    def test_while_else(self):
        hit_else = False
        n = 0
        while n < 3:
            n += 1
        else:
            hit_else = True
        self.assertTrue(hit_else)

    def test_while_else_break(self):
        hit_else = False
        n = 0
        while n < 10:
            n += 1
            if n == 5:
                break
        else:
            hit_else = True
        self.assertFalse(hit_else)


class ForTest(unittest.TestCase):

    def test_for_range(self):
        total = 0
        for i in range(10):
            total += i
        self.assertEqual(total, 45)

    def test_for_list(self):
        result = []
        for x in [1, 2, 3]:
            result.append(x * 2)
        self.assertEqual(result, [2, 4, 6])

    def test_for_string(self):
        chars = []
        for c in "hello":
            chars.append(c)
        self.assertEqual(chars, ['h', 'e', 'l', 'l', 'o'])

    def test_for_dict(self):
        d = {'a': 1, 'b': 2}
        keys = []
        for k in d:
            keys.append(k)
        self.assertEqual(sorted(keys), ['a', 'b'])

    def test_for_tuple_unpack(self):
        pairs = [(1, 'a'), (2, 'b'), (3, 'c')]
        nums = []
        chars = []
        for n, c in pairs:
            nums.append(n)
            chars.append(c)
        self.assertEqual(nums, [1, 2, 3])
        self.assertEqual(chars, ['a', 'b', 'c'])

    def test_nested_for(self):
        result = []
        for i in range(3):
            for j in range(3):
                if i == j:
                    result.append(i)
        self.assertEqual(result, [0, 1, 2])

    def test_for_break(self):
        found = -1
        for i in range(100):
            if i * i > 50:
                found = i
                break
        self.assertEqual(found, 8)

    def test_for_continue(self):
        evens = []
        for i in range(10):
            if i % 2 != 0:
                continue
            evens.append(i)
        self.assertEqual(evens, [0, 2, 4, 6, 8])

    def test_for_else(self):
        hit = False
        for i in range(5):
            pass
        else:
            hit = True
        self.assertTrue(hit)

    def test_for_else_break(self):
        hit = False
        for i in range(5):
            if i == 3:
                break
        else:
            hit = True
        self.assertFalse(hit)


class PassTest(unittest.TestCase):

    def test_pass_in_if(self):
        if True:
            pass
        self.assertTrue(True)

    def test_pass_in_class(self):
        class Empty:
            pass
        self.assertIsNotNone(Empty)

    def test_pass_in_function(self):
        def f():
            pass
        self.assertIsNone(f())

    def test_pass_in_loop(self):
        for i in range(5):
            pass
        self.assertEqual(i, 4)


if __name__ == "__main__":
    unittest.main()
