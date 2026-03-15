"""CPython test_generators.py adapted for apython."""
import unittest


class GeneratorTest(unittest.TestCase):

    def test_basic_generator(self):
        def gen():
            yield 1
            yield 2
            yield 3
        g = gen()
        self.assertEqual(next(g), 1)
        self.assertEqual(next(g), 2)
        self.assertEqual(next(g), 3)
        try:
            next(g)
            self.fail("Expected StopIteration")
        except StopIteration:
            pass

    def test_generator_list(self):
        def gen():
            yield 1
            yield 2
            yield 3
        self.assertEqual(list(gen()), [1, 2, 3])

    def test_generator_for_loop(self):
        def gen(n):
            for i in range(n):
                yield i
        self.assertEqual(list(gen(5)), [0, 1, 2, 3, 4])
        self.assertEqual(list(gen(0)), [])

    def test_generator_expression(self):
        g = (x * x for x in range(5))
        self.assertEqual(list(g), [0, 1, 4, 9, 16])

    def test_generator_with_return(self):
        def gen():
            yield 1
            return
        self.assertEqual(list(gen()), [1])

    def test_generator_send(self):
        def gen():
            x = yield 1
            yield x + 10
        g = gen()
        self.assertEqual(next(g), 1)
        self.assertEqual(g.send(5), 15)

    def test_yield_from(self):
        def inner():
            yield 1
            yield 2
        def outer():
            yield from inner()
            yield 3
        self.assertEqual(list(outer()), [1, 2, 3])

    def test_yield_from_list(self):
        def gen():
            yield from [1, 2, 3]
        self.assertEqual(list(gen()), [1, 2, 3])

    def test_yield_from_range(self):
        def gen():
            yield from range(5)
        self.assertEqual(list(gen()), [0, 1, 2, 3, 4])

    def test_recursive_generator(self):
        def flatten(lst):
            for item in lst:
                if isinstance(item, list):
                    yield from flatten(item)
                else:
                    yield item
        nested = [1, [2, 3], [4, [5, 6]], 7]
        self.assertEqual(list(flatten(nested)), [1, 2, 3, 4, 5, 6, 7])

    def test_generator_closure(self):
        def make_gen(x):
            def gen():
                for i in range(x):
                    yield i * x
            return gen
        g = make_gen(3)
        self.assertEqual(list(g()), [0, 3, 6])

    def test_multiple_generators(self):
        def gen(n):
            for i in range(n):
                yield i
        g1 = gen(3)
        g2 = gen(5)
        self.assertEqual(next(g1), 0)
        self.assertEqual(next(g2), 0)
        self.assertEqual(next(g1), 1)
        self.assertEqual(list(g2), [1, 2, 3, 4])
        self.assertEqual(next(g1), 2)

    def test_generator_filter(self):
        def evens(n):
            for i in range(n):
                if i % 2 == 0:
                    yield i
        self.assertEqual(list(evens(10)), [0, 2, 4, 6, 8])

    def test_fibonacci_generator(self):
        def fib(n):
            a, b = 0, 1
            for _ in range(n):
                yield a
                a, b = b, a + b
        self.assertEqual(list(fib(10)), [0, 1, 1, 2, 3, 5, 8, 13, 21, 34])

    def test_generator_tuple_unpack(self):
        def gen():
            yield 1, 2
            yield 3, 4
        result = list(gen())
        self.assertEqual(result, [(1, 2), (3, 4)])


if __name__ == "__main__":
    unittest.main()
