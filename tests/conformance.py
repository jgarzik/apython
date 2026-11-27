"""Run matched CPython file and package suites and report strict conformance."""

import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
WORKER = ROOT / "tests" / "conformance_worker.py"


def read_outcomes(events, returncode):
    # A test may succeed after reporting a skipped subtest, or report more
    # than one error. Only IDs with exclusively successful outcomes count.
    passed = set()
    missed = set()
    skips = {}
    done = False
    import_error = False
    for outcome, test, reason in events:
        if outcome == "done":
            done = True
        elif outcome == "import" or test.startswith("unittest.loader._FailedTest."):
            import_error = True
        elif outcome == "pass":
            passed.add(test)
        else:
            missed.add(test)
            if outcome == "skip":
                skips[test] = reason
    if returncode is None:
        status = "HANG"
    elif returncode < 0:
        status = "SIGNAL " + signal.Signals(-returncode).name
    elif import_error:
        status = "IMPORT"
    elif not done and returncode:
        status = "ERROR"
    elif skips and not passed and missed == skips.keys():
        status = "SKIP"
    elif not passed and not missed:
        status = "NO RESULTS"
    elif not done:
        status = "INCOMPLETE"
    else:
        status = "COMPLETE"
    if not done or returncode not in (0, 1):
        passed.clear()
    return status, passed - missed, skips


def run_module(side, binary, worker, lib, output, module, source, timeout, limit):
    label = side + "-" + module
    event_path = output / (label + ".jsonl")
    event_path.unlink(missing_ok=True)
    env = os.environ.copy()
    env.update(PYTHONPATH=str(lib), PYTHONDONTWRITEBYTECODE="1")
    # Children inherit the address limit. Keep each test in its own session
    # so even a forked child that outlives the test can be reaped on timeout.
    command = [
        "prlimit", "--as=" + str(limit), "--", binary, worker,
        "test." + module, source or "", event_path,
    ]
    with tempfile.TemporaryDirectory(prefix=label + "-", dir=output) as cwd:
        with (output / (label + ".log")).open("wb") as log:
            with subprocess.Popen(
                command, cwd=cwd, env=env, stdout=log, stderr=log,
                start_new_session=True,
            ) as child:
                try:
                    returncode = child.wait(timeout=timeout)
                except subprocess.TimeoutExpired:
                    returncode = None
                finally:
                    try:
                        os.killpg(child.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    # A fatal exit can cut a write short. The missing completion marker
    # prevents any results from that run contributing to the score.
    events = []
    if event_path.exists():
        with event_path.open(encoding="utf-8", errors="replace") as stream:
            for line in stream:
                if line.endswith("\n"):
                    events.append(json.loads(line))
    return read_outcomes(events, returncode)


def report(results):
    totals = {"files": [0, 0], "packages": [0, 0]}
    reasons = Counter()
    for suite, module, ap, cp in results:
        ap_status, ap_passed, ap_skips = ap
        cp_status, cp_passed, _ = cp
        numerator = len(ap_passed & cp_passed)
        denominator = len(cp_passed)
        totals[suite][0] += numerator
        totals[suite][1] += denominator
        module_skip = ap_skips.get("test." + module)
        for test in cp_passed - ap_passed:
            reason = ap_skips.get(test, module_skip)
            if reason is not None:
                reasons[reason] += 1
        print(f"{module:40} {numerator:5}/{denominator:<5} "
              f"ap {ap_status:<15} cp {cp_status}")
    totals["combined"] = [sum(counts) for counts in zip(*totals.values())]
    for suite, (passed, control) in totals.items():
        percent = f"{passed / control:.2%}" if control else "unavailable"
        print(f"{suite}: {passed}/{control} ({percent})")
    if reasons:
        print("apython skip reasons among CPython passes:")
        for reason, count in sorted(reasons.items(), key=lambda row: (-row[1], row[0])):
            print(f"  {count:5} {reason}")


def sweep(args, modules, output):
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="prefix-", dir=output) as temporary:
        prefix = Path(temporary)
        apython = prefix / "apython"
        shutil.copy2(args.apython, apython)
        worker = prefix / WORKER.name
        shutil.copy2(WORKER, worker)
        (prefix / "lib").symlink_to(ROOT / "lib", target_is_directory=True)
        (prefix / "stdlib").symlink_to(args.lib, target_is_directory=True)
        (prefix / "build").symlink_to(ROOT / "build", target_is_directory=True)

        jobs = {}
        with ThreadPoolExecutor(max_workers=args.jobs) as pool:
            for suite, name, source in modules:
                timeout = args.file_timeout if suite == "files" else args.package_timeout
                for side, binary in (("ap", apython), ("cp", args.cpython)):
                    args_for_module = (side, binary, worker, args.lib, output,
                                       name, source, timeout, args.memory_kib * 1024)
                    jobs[name, side] = pool.submit(run_module, *args_for_module)
            report((suite, name, jobs[name, "ap"].result(), jobs[name, "cp"].result())
                   for suite, name, _ in modules)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("modules", nargs="*", help="optional test module names")
    parser.add_argument("--apython", type=Path, default=ROOT / "apython")
    parser.add_argument("--lib", type=Path, default=os.environ.get(
        "CPYTHON_LIB", Path.home() / "tmp/repo/cpython/Lib"))
    parser.add_argument("--cpython", type=Path, default=os.environ.get(
        "CPYTHON_BIN", Path.home() / "tmp/cpython-build/python"))
    parser.add_argument("--output", type=Path, help="keep per-module logs and events here")
    parser.add_argument("--jobs", type=int, default=6)
    parser.add_argument("--file-timeout", type=int, default=90)
    parser.add_argument("--package-timeout", type=int, default=300)
    parser.add_argument("--memory-kib", type=int, default=3_000_000)
    args = parser.parse_args()
    if min(args.jobs, args.file_timeout, args.package_timeout, args.memory_kib) < 1:
        parser.error("job, timeout, and memory limits must be positive")
    args.lib = args.lib.resolve()
    args.cpython = args.cpython.resolve()
    testdir = args.lib / "test"
    modules = []
    for path in sorted(testdir.glob("test_*")):
        if path.suffix == ".py":
            modules.append(("files", path.stem, path))
        elif (path / "__init__.py").is_file():
            modules.append(("packages", path.name, None))
    requested = set(args.modules)
    if requested:
        unknown = requested - {name for _, name, _ in modules}
        if unknown:
            parser.error("unknown test modules: " + ", ".join(sorted(unknown)))
        modules = [module for module in modules if module[1] in requested]
    if not modules:
        parser.error(f"no tests in {testdir}")
    if not all(os.access(path, os.X_OK) for path in (args.apython, args.cpython)):
        parser.error("set --apython and --cpython to built interpreters")
    version = subprocess.check_output([args.cpython, "--version"], text=True)
    tag = (ROOT / "stdlib" / "VENDORED").read_text().splitlines()[0]
    if version.strip() != tag.replace("CPython v", "Python "):
        parser.error(f"{args.cpython} does not match vendored {tag}")
    patchlevel = args.lib.parent / "Include" / "patchlevel.h"
    if not patchlevel.is_file():
        parser.error(f"could not read reference version from {patchlevel}")
    ref_version = patchlevel.read_text()
    control_version = version.split()[1]
    if not any(line.split()[-1] == '"' + control_version + '"'
               for line in ref_version.splitlines()
               if line.startswith("#define PY_VERSION ")):
        parser.error(f"{args.lib} does not match CPython {control_version}")
    if args.output:
        sweep(args, modules, args.output.resolve())
    else:
        with tempfile.TemporaryDirectory(prefix="apython-conformance-") as temporary:
            sweep(args, modules, Path(temporary))


if __name__ == "__main__":
    main()
