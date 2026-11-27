"""Host-side tests for the conformance report. Run with python3."""

import contextlib
import io
import unittest

from conformance import read_outcomes, report


DONE = ("done", "", "")


class ConformanceTests(unittest.TestCase):
    def test_only_unqualified_passes_count(self):
        status, passed, skips = read_outcomes([
            ("pass", "clean", ""),
            ("pass", "skipped_subtest", ""),
            ("skip", "skipped_subtest", "feature unavailable"),
            ("fail", "failing_subtest", ""),
            ("error", "failing_subtest", ""),
            ("xfail", "known_failure", ""),
            ("xpass", "unexpected_success", ""),
            DONE,
        ], 1)
        self.assertEqual(status, "COMPLETE")
        self.assertEqual(passed, {"clean"})
        self.assertEqual(skips, {"skipped_subtest": "feature unavailable"})

    def test_interrupted_runs_cannot_contribute_passes(self):
        for code, expected in [(None, "HANG"), (-11, "SIGNAL SIGSEGV"),
                               (0, "INCOMPLETE"), (1, "ERROR")]:
            with self.subTest(code=code):
                status, passed, _ = read_outcomes([("pass", "partial", "")], code)
                self.assertEqual(status, expected)
                self.assertEqual(passed, set())

    def test_loader_import_failure(self):
        status, passed, _ = read_outcomes([
            ("error", "unittest.loader._FailedTest.test_example", ""),
            DONE,
        ], 1)
        self.assertEqual(status, "IMPORT")
        self.assertEqual(passed, set())

    def test_score_uses_matching_ids(self):
        rows = [
            ("files", "test_file", ("COMPLETE", {"a", "extra"}, {"b": "missing"}),
             ("COMPLETE", {"a", "b"}, {})),
            ("packages", "test_pkg", ("COMPLETE", {"x"}, {}),
             ("COMPLETE", {"x"}, {"y": "host"})),
        ]
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            report(rows)
        self.assertIn("files: 1/2 (50.00%)", output.getvalue())
        self.assertIn("combined: 2/3 (66.67%)", output.getvalue())
        self.assertIn("1 missing", output.getvalue())
        self.assertNotIn("1 host", output.getvalue())


if __name__ == "__main__":
    unittest.main()
