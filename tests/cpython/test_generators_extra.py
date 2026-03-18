"""Extra generator tests"""

import unittest


class GeneratorBasicTest(unittest.TestCase):

    def test_simple_yield(self):
        def gen():
            yield 1
            yield 2
            yield 3
        self.assertEqual(list(gen()), [1, 2, 3])

    def test_yield_from_loop(self):
        def gen(n):
            for i in range(n):
                yield i
        self.assertEqual(list(gen(5)), [0, 1, 2, 3, 4])

    def test_yield_with_return(self):
        def gen():
            yield 1
            yield 2
            return
            yield 3  # unreachable
        self.assertEqual(list(gen()), [1, 2])

    def test_empty_generator(self):
        def gen():
            return
            yield  # makes it a generator
        self.assertEqual(list(gen()), [])

    def test_generator_next(self):
        def gen():
            yield 'a'
            yield 'b'
        g = gen()
        self.assertEqual(next(g), 'a')
        self.assertEqual(next(g), 'b')
        self.assertRaises(StopIteration, next, g)

    def test_fibonacci(self):
        def fib():
            a, b = 0, 1
            while True:
                yield a
                a, b = b, a + b
        g = fib()
        result = [next(g) for _ in range(10)]
        self.assertEqual(result, [0, 1, 1, 2, 3, 5, 8, 13, 21, 34])

    def test_generator_send(self):
        def echo():
            val = yield "start"
            while True:
                val = yield val
        g = echo()
        self.assertEqual(next(g), "start")
        self.assertEqual(g.send("hello"), "hello")
        self.assertEqual(g.send(42), 42)

    def test_generator_in_for(self):
        def squares(n):
            for i in range(n):
                yield i * i
        self.assertEqual(list(squares(5)), [0, 1, 4, 9, 16])

    def test_multiple_generators(self):
        def gen(start):
            for i in range(start, start + 3):
                yield i
        g1 = gen(0)
        g2 = gen(10)
        self.assertEqual(next(g1), 0)
        self.assertEqual(next(g2), 10)
        self.assertEqual(next(g1), 1)
        self.assertEqual(next(g2), 11)

    def test_generator_closure(self):
        def make_counter(start):
            def gen():
                n = start
                while True:
                    yield n
                    n += 1
            return gen()
        c = make_counter(100)
        self.assertEqual(next(c), 100)
        self.assertEqual(next(c), 101)
        self.assertEqual(next(c), 102)


class YieldFromTest(unittest.TestCase):

    def test_yield_from_list(self):
        def gen():
            yield from [1, 2, 3]
        self.assertEqual(list(gen()), [1, 2, 3])

    def test_yield_from_generator(self):
        def inner():
            yield 'a'
            yield 'b'
        def outer():
            yield from inner()
            yield 'c'
        self.assertEqual(list(outer()), ['a', 'b', 'c'])

    def test_yield_from_range(self):
        def gen():
            yield from range(5)
        self.assertEqual(list(gen()), [0, 1, 2, 3, 4])

    def test_yield_from_string(self):
        def gen():
            yield from "abc"
        self.assertEqual(list(gen()), ['a', 'b', 'c'])

    def test_chained_yield_from(self):
        def gen1():
            yield 1
            yield 2
        def gen2():
            yield 3
            yield 4
        def combined():
            yield from gen1()
            yield from gen2()
        self.assertEqual(list(combined()), [1, 2, 3, 4])


class GeneratorExprTest(unittest.TestCase):

    def test_basic_genexp(self):
        g = (x * 2 for x in range(5))
        self.assertEqual(list(g), [0, 2, 4, 6, 8])

    def test_filtered_genexp(self):
        g = (x for x in range(10) if x % 3 == 0)
        self.assertEqual(list(g), [0, 3, 6, 9])

    def test_genexp_sum(self):
        self.assertEqual(sum(x * x for x in range(10)), 285)

    def test_genexp_any_all(self):
        self.assertTrue(any(x > 5 for x in range(10)))
        self.assertTrue(all(x >= 0 for x in range(10)))
        self.assertFalse(all(x > 5 for x in range(10)))


if __name__ == "__main__":
    unittest.main()
