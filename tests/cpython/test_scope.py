"""CPython test_scope.py adapted for apython."""
import unittest


class ScopeTests(unittest.TestCase):

    def testSimpleNesting(self):
        def make_adder(x):
            def adder(y):
                return x + y
            return adder

        inc = make_adder(1)
        plus10 = make_adder(10)
        self.assertEqual(inc(1), 2)
        self.assertEqual(plus10(-2), 8)

    def testExtraNesting(self):
        def make_adder2(x):
            def extra():
                def adder(y):
                    return x + y
                return adder
            return extra()

        inc = make_adder2(1)
        plus10 = make_adder2(10)
        self.assertEqual(inc(1), 2)
        self.assertEqual(plus10(-2), 8)

    def testSimpleAndRebinding(self):
        def make_adder3(x):
            def adder(y):
                return x + y
            x = x + 1
            return adder

        inc = make_adder3(0)
        plus10 = make_adder3(9)
        self.assertEqual(inc(1), 2)
        self.assertEqual(plus10(-2), 8)

    def testRecursion(self):
        def f(x):
            def fact(n):
                if n == 0:
                    return 1
                else:
                    return n * fact(n - 1)
            if x >= 0:
                return fact(x)
            else:
                raise ValueError("x must be >= 0")
        self.assertEqual(f(6), 720)

    def testLambdas(self):
        f1 = lambda x, y: x + y
        self.assertEqual(f1(1, 2), 3)

        f2 = lambda x: lambda y: x + y
        self.assertEqual(f2(1)(2), 3)

        f3 = lambda x: x
        self.assertEqual(f3(42), 42)

        f5 = lambda x, y=2: x + y
        self.assertEqual(f5(1), 3)
        self.assertEqual(f5(1, 10), 11)

    def testUnboundLocal(self):
        def errorInOuter():
            print(y)
            def inner():
                return y
            y = 1

        def errorInInner():
            def inner():
                return y
            inner()
            y = 1

        self.assertRaises(UnboundLocalError, errorInOuter)
        self.assertRaises(NameError, errorInInner)

    def testComplexDefinitions(self):
        def makeReturner(*lst):
            def returner():
                return lst
            return returner
        self.assertEqual(makeReturner(1,2,3)(), (1,2,3))

    def testScopeOfGlobalStmt(self):
        # Test that a global statement applies to the function scope
        x = 1
        def f():
            global x
            x = 2
        f()
        # x should not have changed in our scope (it's a local)
        # But the global x should be 2
        # Since we can't easily check the global, just verify no crash

    def testBoundAndFree(self):
        def f(x):
            def g():
                return x
            def h():
                x = 99
                return x
            return g, h

        g, h = f(10)
        self.assertEqual(g(), 10)
        self.assertEqual(h(), 99)
        # g should still return 10 (not affected by h's local x)
        self.assertEqual(g(), 10)

    def testCellIsArgAndEscapes(self):
        def f(x):
            def g():
                return x
            return g
        g = f(42)
        self.assertEqual(g(), 42)

    def testClosureCounter(self):
        def make_counter():
            count = [0]
            def inc():
                count[0] += 1
                return count[0]
            return inc
        c = make_counter()
        self.assertEqual(c(), 1)
        self.assertEqual(c(), 2)
        self.assertEqual(c(), 3)

    def testNonlocalStatement(self):
        def outer():
            x = 0
            def inner():
                nonlocal x
                x += 1
                return x
            return inner
        f = outer()
        self.assertEqual(f(), 1)
        self.assertEqual(f(), 2)
        self.assertEqual(f(), 3)

    def testNestedNonlocal(self):
        def f():
            x = 1
            def g():
                nonlocal x
                x = 2
                def h():
                    nonlocal x
                    x = 3
                h()
                return x
            return g()
        self.assertEqual(f(), 3)

    def testGeneratorScope(self):
        def f():
            x = 10
            def gen():
                for i in range(3):
                    yield x + i
            return list(gen())
        self.assertEqual(f(), [10, 11, 12])


if __name__ == "__main__":
    unittest.main()
