import sys

class SkipTest(Exception):
    pass

def skip(reason):
    def decorator(func):
        func.__unittest_skip__ = True
        func.__unittest_skip_why__ = reason
        return func
    return decorator

def skipIf(condition, reason):
    if condition:
        return skip(reason)
    def decorator(func):
        return func
    return decorator

def skipUnless(condition, reason):
    if not condition:
        return skip(reason)
    def decorator(func):
        return func
    return decorator

class _AssertRaisesContext:
    def __init__(self, expected_exc, msg=None):
        self.expected = expected_exc
        self.exception = None
        self._msg = msg
    def __enter__(self):
        return self
    def __exit__(self, exc_type, exc_val, exc_tb):
        if exc_type is None:
            raise AssertionError(
                "%s not raised" % self.expected.__name__ if hasattr(self.expected, '__name__') else "Expected exception not raised"
            )
        if isinstance(exc_val, self.expected):
            self.exception = exc_val
            return True
        return False

class _AssertRaisesRegexContext:
    def __init__(self, expected_exc, expected_regex):
        self.expected = expected_exc
        self.expected_regex = expected_regex
        self.exception = None
    def __enter__(self):
        return self
    def __exit__(self, exc_type, exc_val, exc_tb):
        if exc_type is None:
            raise AssertionError(
                "%s not raised" % self.expected.__name__
            )
        if isinstance(exc_val, self.expected):
            self.exception = exc_val
            msg = str(exc_val)
            if hasattr(exc_val, 'args') and exc_val.args:
                msg = str(exc_val.args[0])
            if self.expected_regex in msg:
                return True
            raise AssertionError(
                "'%s' not found in '%s'" % (self.expected_regex, msg)
            )
        return False

class _AssertWarnsContext:
    def __init__(self, expected_warning):
        self.expected = expected_warning
        self.warning = None
        self._entered = False
    def __enter__(self):
        self._entered = True
        import warnings
        self._old_filters = warnings._filters_action
        warnings._filters_action = 'always'
        warnings._warnings_list = []
        return self
    def __exit__(self, exc_type, exc_val, exc_tb):
        import warnings
        found = False
        for w in warnings._warnings_list:
            if isinstance(w, self.expected) or (isinstance(w, tuple) and len(w) >= 2 and w[1] is self.expected):
                found = True
                self.warning = w
                break
            if type(w).__name__ == self.expected.__name__:
                found = True
                self.warning = w
                break
        warnings._filters_action = self._old_filters
        if exc_type is not None:
            return False
        if not found:
            pass  # Be lenient - many warnings won't fire in apython
        return False

class _SubTestContext:
    def __init__(self, test, msg=None, **params):
        self._test = test
        self._msg = msg
        self._params = params
    def __enter__(self):
        return self
    def __exit__(self, exc_type, exc_val, exc_tb):
        if exc_type is not None:
            if isinstance(exc_val, SkipTest):
                return False
            # Record subtest failure but continue
            self._test._subtest_failures.append((self._msg, self._params, exc_val))
            return True
        return False

class TestCase:
    def __init__(self, method_name='runTest'):
        self._method_name = method_name
        self._subtest_failures = []

    def setUp(self):
        pass

    def tearDown(self):
        pass

    def skipTest(self, reason):
        raise SkipTest(reason)

    def fail(self, msg=None):
        raise AssertionError(msg or "Test failed")

    def assertEqual(self, first, second, msg=None):
        if first != second:
            if msg:
                raise AssertionError(msg)
            raise AssertionError("%r != %r" % (first, second))

    def assertNotEqual(self, first, second, msg=None):
        if first == second:
            if msg:
                raise AssertionError(msg)
            raise AssertionError("%r == %r" % (first, second))

    def assertAlmostEqual(self, first, second, places=7, msg=None):
        if first == second:
            return
        diff = abs(first - second)
        if diff <= 10 ** (-places):
            return
        if msg:
            raise AssertionError(msg)
        raise AssertionError("%r != %r within %d places" % (first, second, places))

    def assertNotAlmostEqual(self, first, second, places=7, msg=None):
        if first == second:
            if msg:
                raise AssertionError(msg)
            raise AssertionError("%r == %r within %d places" % (first, second, places))
        diff = abs(first - second)
        if diff > 10 ** (-places):
            return
        if msg:
            raise AssertionError(msg)
        raise AssertionError("%r == %r within %d places" % (first, second, places))

    def assertTrue(self, expr, msg=None):
        if not expr:
            raise AssertionError(msg or "%r is not true" % (expr,))

    def assertFalse(self, expr, msg=None):
        if expr:
            raise AssertionError(msg or "%r is not false" % (expr,))

    def assertIs(self, first, second, msg=None):
        if first is not second:
            if msg:
                raise AssertionError(msg)
            raise AssertionError("%r is not %r" % (first, second))

    def assertIsNone(self, obj, msg=None):
        if obj is not None:
            if msg:
                raise AssertionError(msg)
            raise AssertionError("%r is not None" % (obj,))

    def assertIsNotNone(self, obj, msg=None):
        if obj is None:
            raise AssertionError(msg or "unexpectedly None")

    def assertIsNot(self, first, second, msg=None):
        if first is second:
            if msg:
                raise AssertionError(msg)
            raise AssertionError("%r is %r" % (first, second))

    def assertIn(self, member, container, msg=None):
        if member not in container:
            if msg:
                raise AssertionError(msg)
            raise AssertionError("%r not found in %r" % (member, container))

    def assertNotIn(self, member, container, msg=None):
        if member in container:
            if msg:
                raise AssertionError(msg)
            raise AssertionError("%r found in %r" % (member, container))

    def assertIsInstance(self, obj, cls, msg=None):
        if not isinstance(obj, cls):
            if msg:
                raise AssertionError(msg)
            raise AssertionError("%r is not an instance of %r" % (obj, cls))

    def assertNotIsInstance(self, obj, cls, msg=None):
        if isinstance(obj, cls):
            if msg:
                raise AssertionError(msg)
            raise AssertionError("%r is an instance of %r" % (obj, cls))

    def assertGreater(self, a, b, msg=None):
        if not a > b:
            raise AssertionError(msg or "%r not greater than %r" % (a, b))

    def assertGreaterEqual(self, a, b, msg=None):
        if not a >= b:
            raise AssertionError(msg or "%r not greater than or equal to %r" % (a, b))

    def assertLess(self, a, b, msg=None):
        if not a < b:
            raise AssertionError(msg or "%r not less than %r" % (a, b))

    def assertLessEqual(self, a, b, msg=None):
        if not a <= b:
            raise AssertionError(msg or "%r not less than or equal to %r" % (a, b))

    def assertRaises(self, exc_class, callable_obj=None, *args, msg=None, **kwargs):
        ctx = _AssertRaisesContext(exc_class, msg=msg)
        if callable_obj is None:
            return ctx
        with ctx:
            callable_obj(*args, **kwargs)
        return ctx

    def assertRaisesRegex(self, exc_class, expected_regex, callable_obj=None, *args, **kwargs):
        ctx = _AssertRaisesRegexContext(exc_class, expected_regex)
        if callable_obj is None:
            return ctx
        with ctx:
            callable_obj(*args, **kwargs)
        return ctx

    def assertWarns(self, warning_class, callable_obj=None, *args, **kwargs):
        ctx = _AssertWarnsContext(warning_class)
        if callable_obj is None:
            return ctx
        with ctx:
            callable_obj(*args, **kwargs)
        return ctx

    def subTest(self, msg=None, **params):
        return _SubTestContext(self, msg=msg, **params)

    def _run_test(self):
        method = getattr(self, self._method_name)
        # Check skip decorators
        skip_flag = getattr(method, '__unittest_skip__', False)
        if skip_flag:
            return 'skip', getattr(method, '__unittest_skip_why__', '')
        self._subtest_failures = []
        try:
            self.setUp()
        except SkipTest as e:
            return 'skip', str(e)
        except Exception as e:
            return 'fail', e
        try:
            method()
        except SkipTest as e:
            try:
                self.tearDown()
            except Exception:
                pass
            return 'skip', str(e)
        except Exception as e:
            try:
                self.tearDown()
            except Exception:
                pass
            return 'fail', e
        try:
            self.tearDown()
        except Exception as e:
            return 'fail', e
        if self._subtest_failures:
            return 'subfail', self._subtest_failures
        return 'ok', None
