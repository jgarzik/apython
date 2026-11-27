"""Record unittest outcomes while running one CPython test file or package."""

import json
import os
import runpy
import sys
import unittest


class RecordingResult(unittest.TextTestResult):
    def record(self, outcome, test, reason=""):
        # unittest sends skipped subtests to addSkip, not addSubTest.
        test = getattr(test, "test_case", test)
        name = test.id()
        if name.startswith("__main__."):
            name = module + name[len("__main__"):]
        events.write(json.dumps([outcome, name, reason]) + "\n")

    def addSuccess(self, test):
        super().addSuccess(test)
        self.record("pass", test)

    def addFailure(self, test, err):
        super().addFailure(test, err)
        self.record("fail", test)

    def addError(self, test, err):
        super().addError(test, err)
        self.record("error", test)

    def addSkip(self, test, reason):
        super().addSkip(test, reason)
        self.record("skip", test, reason)

    def addExpectedFailure(self, test, err):
        super().addExpectedFailure(test, err)
        self.record("xfail", test)

    def addUnexpectedSuccess(self, test):
        super().addUnexpectedSuccess(test)
        self.record("xpass", test)

    def addSubTest(self, test, subtest, err):
        super().addSubTest(test, subtest, err)
        if err is not None:
            self.record("fail", test)


def run_recording(runner, test):
    global recording
    # Some suites exercise unittest itself. Their nested runners must keep
    # their original results, and their test IDs do not belong to this run.
    if recording or runner.resultclass is not unittest.TextTestResult:
        return run_unittest(runner, test)
    recording = True
    original = runner.__dict__.get("resultclass")
    runner.resultclass = RecordingResult
    try:
        return run_unittest(runner, test)
    finally:
        if original is None:
            del runner.resultclass
        else:
            runner.resultclass = original
        recording = False


def allow_behavioral_tests(names):
    # Keep sys.implementation and every other implementation guard intact.
    # Only lift this decorator for the definitions named by the scope file.
    from test import support
    cpython_only = support.cpython_only

    def decorate(obj):
        namespace = module if obj.__module__ == "__main__" else obj.__module__
        if namespace + "." + obj.__qualname__ in names:
            return obj
        return cpython_only(obj)

    support.cpython_only = decorate


if __name__ == "__main__":
    module, source, event_path, *retests = sys.argv[1:]
    with open(event_path, "w", buffering=1, encoding="utf-8") as events:
        recording = False
        run_unittest = unittest.TextTestRunner.run
        unittest.TextTestRunner.run = run_recording
        if retests:
            allow_behavioral_tests(retests)
        try:
            if source:
                sys.argv[:] = [source]
                sys.path[0] = os.path.dirname(source)
                runpy.run_path(source, run_name="__main__")
            else:
                unittest.main(module=None, argv=[sys.argv[0], module])
        except unittest.SkipTest as exc:
            events.write(json.dumps(["skip", module, str(exc)]) + "\n")
        except ImportError:
            events.write('["import", "", ""]\n')
            raise
        except SystemExit as exc:
            if exc.code in (None, 0, 1):
                events.write('["done", "", ""]\n')
            raise
        else:
            events.write('["done", "", ""]\n')
