"""Interactive stdio is flushed while the child is still reading commands."""

import select
import subprocess
import sys


result = subprocess.run([sys.executable], input=b"import sys; print(sys.argv)\n",
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
assert result.returncode == 0, result.stderr
assert result.stdout == b"['']\n", result.stdout
assert result.stderr == b"", result.stderr

with subprocess.Popen([sys.executable, "-iq", "-c", "answer = 42"],
                      stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                      stderr=subprocess.PIPE) as process:
    try:
        assert select.select([process.stderr], [], [], 5)[0]
        assert process.stderr.read(4) == b">>> "
        process.stdin.write(b"answer\n")
        process.stdin.flush()
        assert select.select([process.stdout], [], [], 5)[0]
        assert process.stdout.readline() == b"42\n"
        stdout, stderr = process.communicate(b"1/0\nprint('still running')\n", timeout=10)
        assert process.returncode == 0, stderr
        assert b'File "<stdin>"' in stderr, stderr
        assert b"ZeroDivisionError" in stderr, stderr
        assert stdout == b"still running\n", stdout
    finally:
        if process.poll() is None:
            process.kill()

print("interactive prompts, output, and exceptions")
