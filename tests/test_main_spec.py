import subprocess
import sys
from pathlib import Path
from tempfile import TemporaryDirectory


assert __spec__ is None

module_source = """
import __main__
assert __main__.__spec__.name == 'probe'
assert __main__.__loader__ is __main__.__spec__.loader
assert __main__.__cached__ == __main__.__spec__.cached
"""

with TemporaryDirectory() as directory:
    Path(directory, "probe.py").write_text(module_source)
    subprocess.run([sys.executable, "-m", "probe"], cwd=directory,
                   check=True, timeout=10)
