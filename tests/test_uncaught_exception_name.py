# An uncaught exception's last traceback line names its class the way
# traceback.py does: qualified by the module unless that is __main__ or
# builtins -- "subprocess.CalledProcessError: ...", "__main__"'s own "E: ...".
# The interpreter's own renderer printed the bare name for all of them.
import subprocess
import sys

cases = [
    "import subprocess; raise subprocess.CalledProcessError(1, 'x')",
    "class E(Exception): pass\nraise E('mine')",
    "raise ValueError('builtin')",
    "import json; json.loads('{')",
    "class Outer:\n class Inner(Exception): pass\nraise Outer.Inner('nested')",
    "import types; E = types.new_class('E', (Exception,)); E.__module__ = 'pkg.mod'; raise E('m')",
]
for src in cases:
    out = subprocess.run([sys.executable, "-c", src], capture_output=True, text=True)
    print(out.stderr.strip().splitlines()[-1], out.returncode)
