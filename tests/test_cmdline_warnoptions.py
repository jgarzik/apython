# The warnings an interpreter starts with: CPython's five default filters
# (DeprecationWarning shown only from __main__), and -W, PYTHONWARNINGS, -b
# and -X dev collected into sys.warnoptions in CPython's order, -X options
# into sys._xoptions.  The filter list was empty, so every library's
# deprecation reached the user, and -W and -X were parsed and dropped.
import os
import subprocess
import sys
import warnings

print([(a, c.__name__, m) for a, _, c, m, _ in warnings.filters[-5:]])

probe = ("import sys, warnings; print(sys.warnoptions); "
         "print(sorted(sys._xoptions.items())); print(sys.flags.dev_mode); "
         "print([(a, c.__name__) for a, _, c, _, _ in warnings.filters[:4]])")
env = dict(os.environ, PYTHONWARNINGS="ignore,,once")
for args in (["-W", "error"], ["-X", "dev", "-X", "k=v", "-W", "always"],
             ["-bb"], ["-E", "-W", "default"]):
    out = subprocess.run([sys.executable, *args, "-c", probe], env=env,
                         capture_output=True, text=True)
    print(args, out.stdout.strip().splitlines(), out.returncode)
