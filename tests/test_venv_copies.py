# A venv made with copies of the interpreter rather than symlinks finds the
# installation it came from through pyvenv.cfg's `home`, as CPython's getpath
# does: its own sys.prefix, the base install's sys.base_prefix, and a working
# standard library.  The copied binary used to find no library at all.
import os
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory() as tmp:
    env = os.path.join(tmp, "v")
    r = subprocess.run([sys.executable, "-m", "venv", "--copies", "--without-pip", env],
                       capture_output=True, text=True)
    print("created", r.returncode)
    exe = os.path.join(env, "bin", "python")
    print("copied", os.path.isfile(exe) and not os.path.islink(exe))
    probe = ("import sys, json, os; "
             "print(sys.prefix == os.path.dirname(os.path.dirname(sys.executable))); "
             "print(sys.base_prefix != sys.prefix); "
             "print(json.dumps([1]))")
    out = subprocess.run([exe, "-c", probe], capture_output=True, text=True)
    print(out.stdout.split(), out.returncode)
